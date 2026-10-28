# BigQuery for Swift Design Specification

## Intent

Provide an idiomatic Swift 6 veneer client library (`GoogleCloudBigQuery` in `pkgs/swift-google-cloud-bigquery`) covering the complete Google Cloud BigQuery v2 REST API surface with parity against the Java client (`google-cloud-bigquery`). Target users are Swift server and data engineers querying datasets, managing tables, routines, and ML models, streaming rows via `insertAll`, and uploading data via resumable jobs.

### Goals

- Cover all operations on the BigQuery v2 API: datasets, tables, routines, models, jobs (query, load, extract, copy), the `jobs.query` fast path, stateless queries, `tabledata.insertAll`, `tabledata.list`, table IAM, and resumable uploads.
- Provide an idiomatic Swift 6 API built on `async` and `await`, `Sendable` value types, `AsyncSequence` pagination, and strongly typed resource identifiers.
- Keep generated wire models (`GoogleCloudBigQueryV2`) and HTTP transport details internal to the veneer package.
- Achieve streaming row read throughput and memory footprint competitive with or better than Java on multi-million-row result sets.

### Non-Goals

- Storage Read API and Apache Arrow serialization (deferred until a generated Storage v1 module and Swift Arrow dependency exist in the repository).
- Codable row decoding (RowDecoder).
- Beta `Connection` API, OpenTelemetry tracing spans, schema inference from `Encodable`, and automatic whole-query job retry.

### Hand-written veneer over generated v2 wire models

`librarian` generates `generated/swift-google-cloud-bigquery-v2` (`GoogleCloudBigQueryV2`), and the handwritten veneer imports it internally for wire messages only while sending HTTP requests through `BigQueryTransport` built on `GoogleGax._HTTPClient` and `_RetryLoop`. The generated REST client is not used directly because it drops structured `error.errors[]` entries and fails on empty `204 No Content` delete responses.

### Explicit job creation mode

Job creation mode is unset by default on both `QueryJobConfiguration.jobCreationMode` and `BigQueryClientOptions.defaultJobCreationMode`. The client never opts into `JOB_CREATION_OPTIONAL` silently because optional mode omits job IDs that callers may inspect.

### Automatic UUID insertId generation for insertAll

`insertAll` generates a UUID `insertId` for every row that does not supply one. Callers can provide explicit IDs or opt out with `insertIDs: .none`, which also disables HTTP retry on that call because retrying without deduplication IDs can duplicate rows.

### Task cancellation does not cancel server-side jobs

Cancelling the calling Swift `Task` stops local polling or page iteration without sending a `jobs.cancel` RPC. Server-side cancellation requires an explicit `cancelJob` call so client task lifetimes never trigger unintended remote mutations.

### Standard SQL by default

Every query request and view definition sends `useLegacySql = false` unless explicitly overridden. When reading a job or view from the server, an omitted `useLegacySql` field is interpreted as legacy SQL to match BigQuery wire defaults.

## Runtime and Transport Hooks

Slice `0A` adds minimal `@_spi(Internal)` hooks in `GoogleGax` so `GoogleCloudBigQuery` can issue custom multipart or resumable HTTP requests.

### Contract: HTTPClientHolder exposes raw HTTP requests via SPI

`_HTTPClient.executeRaw` and `HTTPClientResponse` expose raw request execution, response status codes, headers, and byte buffers under `@_spi(Internal)` so sibling veneer packages can implement resumable upload protocols and custom empty-body handling while sharing authentication and retry loops.

## Generated Wire Module

Slice `0B` registers `swift-google-cloud-bigquery-v2` in `librarian.yaml` and `generated/_libraries.json` and checks in the generated v2 wire models and snippets.

### Contract: Librarian generates GoogleCloudBigQueryV2 wire models

The `generated/swift-google-cloud-bigquery-v2` package exposes generated BigQuery v2 REST message types and snippets that compile cleanly under Swift 6 strict concurrency.

## Core Client and Transport

Slice `1` establishes the `GoogleCloudBigQuery` package manifest, `BigQueryClient`, `BigQueryClientOptions`, `BigQueryTransport`, `BigQueryError`, `BigQueryRetryPolicy`, resource identifiers (`ProjectID`, `DatasetID`, `TableID`, `RoutineID`, `ModelID`, `JobID`), `Schema`, and `PagedSequence`.

### Contract: BigQueryClient resolves project ID and installs default retry policy

`BigQueryClient.init(_:)` resolves the default project ID from `BigQueryClientOptions.projectID` or environment discovery (`GOOGLE_CLOUD_PROJECT`, `GCLOUD_PROJECT`), defaults the per-attempt timeout to 60 seconds, and installs `BigQueryRetryPolicy.defaultPolicy` when no custom retry policy is configured.

### Contract: Resource IDs validate and format canonical identifiers

`DatasetID`, `TableID`, `RoutineID`, `ModelID`, and `JobID` validate non-empty identifiers, preserve optional project and location fields, and format standard BigQuery reference strings (`project:dataset.table` or `dataset.table` when project is omitted).

### Contract: BigQueryError maps HTTP status and reason codes to typed kinds

`BigQueryError` parses BigQuery REST error payloads (`error.code`, `error.message`, `error.errors[].reason`, and `location`) into structured error kinds (`notFound`, `duplicate`, `accessDenied`, `invalid`, `rateLimitExceeded`, `backendError`, `jobFailed`) and classifies retryable server errors (`500`, `502`, `503`, `504`, `backendError`, `rateLimitExceeded`) for `BigQueryRetryPolicy`.

### Contract: PagedSequence iterates pages lazily via AsyncSequence

`PagedSequence` fetches the initial page on iterator creation and requests subsequent pages using `nextPageToken` only as the caller advances across page boundaries, terminating when `nextPageToken` is `nil` or empty.

## Scalar and SQL Value Types

Slice `2A` implements BigQuery scalar value types (`CivilDate`, `CivilTime`, `CivilDateTime`, `BigNumeric`, `BigQueryTimestamp`, `Interval`, and `RoutineDataTypes`).

### Contract: Civil date time and datetime preserve sub-microsecond components

`CivilDate`, `CivilTime`, and `CivilDateTime` parse and format canonical BigQuery wire strings (`YYYY-MM-DD`, `HH:MM:SS[.ffffff]`, and `YYYY-MM-DDTHH:MM:SS[.ffffff]`) with full microsecond precision and round-trip losslessly through `Codable`.

### Contract: BigNumeric preserves 38-digit scale and converts to Decimal

`BigNumeric` stores exact 76.38 fixed-point decimal strings without floating-point precision loss and provides `decimalValue` conversion to `Foundation.Decimal`.

### Contract: BigQueryTimestamp supports microsecond and picosecond wire formats

`BigQueryTimestamp` parses both epoch-float strings and ISO-8601 timestamp strings with up to 12 fractional digits (picoseconds), decomposing into whole seconds and picosecond remainder without precision loss.

## Row and Field Value Accessors

Slice `2B` implements `Row`, `FieldValue`, `BigQueryRange`, and `RowSequence`.

### Contract: Row and FieldValue unwrap REST table cells by index and column name

`Row` decodes BigQuery REST `{"f":[{"v":...}]}` row objects alongside a `Schema`, providing zero-based positional indexing (`row[0]`) and case-insensitive column-name lookup (`row["col"]`) into typed `FieldValue` cases (`null`, `string`, `integer`, `float`, `boolean`, `bytes`, `timestamp`, `date`, `time`, `dateTime`, `numeric`, `bigNumeric`, `interval`, `geography`, `json`, `range`, `array`, and `record`).

### Contract: BigQueryRange parses half-open bounds for date datetime and timestamp

`BigQueryRange` parses `[lower, upper)` range wire literals, treating `UNBOUNDED` and `NULL` endpoints as unbounded (`nil`) and decoding bounded endpoints according to the schema's `rangeElementType` (`DATE`, `DATETIME`, or `TIMESTAMP`).

## Datasets, Projects, and Table IAM

Slice `3A` implements `Dataset`, `Acl`, `Project`, `IAMPolicy`, and the `BigQueryClient` dataset, project, and table IAM operations.

### Contract: Dataset CRUD and delete treat 404 as idempotent false

`getDataset` returns `nil` on HTTP `404`, and `deleteDataset` returns `false` on HTTP `404` and `true` when the dataset is deleted, forwarding `deleteContents` as a query parameter.

### Contract: Table IAM get set and test permissions preserve policy etags

`getIAMPolicy`, `setIAMPolicy`, and `testIAMPermissions` invoke the BigQuery table IAM endpoints and preserve policy `etag`, `version`, bindings, and conditional expressions.

## Tables and External Data Configuration

Slice `3B` implements `Table`, `TableDefinition` (`StandardTableDefinition`, `ViewDefinition`, `MaterializedViewDefinition`, `ExternalTableDefinition`, `SnapshotTableDefinition`, `CloneDefinition`), `ExternalDataConfiguration`, `TableConstraints`, and `BigQueryClient+Tables`.

### Contract: Table CRUD and delete treat 404 as idempotent false

`getTable` returns `nil` on HTTP `404`, and `deleteTable` returns `false` on HTTP `404` and `true` on HTTP `200` or `204`. `createTable`, `updateTable`, `patchTable`, and `listTables` preserve schema, partitioning, clustering, encryption, and view definitions.

### Contract: ExternalDataConfiguration encodes format-specific options

`ExternalDataConfiguration` encodes and decodes CSV, Parquet, Avro, ORC, Google Sheets, Bigtable, Datastore, and BigLake options along with hive partitioning and decimal target types.

## TableData List

Slice `3C` implements `BigQueryClient+TableData` (`listRows`) and `BigQueryClient+Tables`.

### Contract: listRows requests ISO8601 timestamps and Int64 encoding

`listRows` calls `tabledata.list` with `formatOptions.useInt64Timestamp = true` (or `timestampOutputFormat = ISO8601_STRING` when picosecond timestamp columns are present in the schema) and returns a `RowSequence` over all pages.

## Streaming Inserts

Slice `3C2` implements `BigQueryClient+InsertAll` (`insertAll`, `InsertRow`, `InsertRowEncoder`, `InsertAllResponse`).

### Contract: insertAll generates UUID insert IDs and disables retry when opted out

`insertAll` encodes `[InsertRow]` or `[Encodable]` rows via `InsertRowEncoder`, assigns a random UUID `insertId` to each row when `insertIDs` is `.generate` (the default), omits `insertId` and disables retry when `insertIDs` is `.none`, and returns per-row `InsertAllResponse.RowError` entries without throwing when the HTTP call succeeds with partial row errors.

## Routines and ML Models

Slice `3D` implements `Routine`, `Model`, `BigQueryClient+Routines`, and `BigQueryClient+Models`.

### Contract: Routine and model CRUD follow idempotent 404 delete semantics

`getRoutine` and `getModel` return `nil` on HTTP `404`, `deleteRoutine` and `deleteModel` return `false` on HTTP `404` and `true` on deletion, and `listRoutines` and `listModels` paginate full resource metadata efficiently.

## Job Models, Statistics, and Configurations

Slice `4A` implements `JobStatus`, `JobStatistics` (query, load, copy, extract, reservation, script, transaction, and BI Engine statistics), `JobConfiguration`, `LoadJobConfiguration`, `CopyJobConfiguration`, and `ExtractJobConfiguration`.

### Contract: Job configurations discriminate query load copy and extract payloads

`JobConfiguration` maps the four BigQuery job payload variants (`query`, `load`, `copy`, `extract`) along with job labels, timeouts, dry-run flags, and typed per-job `JobStatistics` on readback.

## Query Parameters and Query Configuration

Slice `4B` implements `QueryParameter`, `QueryParameterValue` (factories and `QueryParameterValueConvertible`), `QueryJobConfiguration`, `Job`, and `QueryResult`.

### Contract: QueryJobConfiguration defaults to standard SQL and encodes typed parameters

`QueryJobConfiguration` sets `useLegacySQL = false` by default and encodes both named (`@name`) and positional (`?`) `QueryParameter` values (scalars, arrays, structs, and ranges) with explicit `QueryParameterType` wire metadata.

## Job Lifecycle and Polling

Slice `4C` implements `BigQueryClient+Jobs` (`createJob`, `getJob`, `cancelJob`, `deleteJob`, `listJobs`, `waitForJob`, and `runJob`).

### Contract: waitForJob polls until DONE and surfaces status errorResult

`waitForJob` polls `jobs.get` using the configured polling backoff until `status.state == .done`, then throws `BigQueryError` (with kind `.jobFailed` and all `status.errors`) if `status.errorResult` is present, or returns the completed `Job`.

## Query Execution Fast and Slow Paths

Slice `4D` implements `BigQueryClient+Query` (`query`, `queryJob`, `getQueryResults`, and `dryRunQuery`).

### Contract: query uses jobs.query fast path when eligible and falls back to jobs.insert

`BigQueryClient.query` uses the synchronous `jobs.query` RPC when the `QueryJobConfiguration` only sets fields supported by `QueryRequest`, and automatically falls back to `jobs.insert` + `waitForJob` + `tabledata.list` (or `jobs.getQueryResults` for script/DML queries without a destination table) when advanced job configuration fields are set or when `jobs.query` returns `jobComplete == false`.

## Resumable Upload Client

Slice `4E` implements `UploadSource` and `BigQueryClient+Upload` (`upload`, `loadFromFile`, `loadFromData`).

### Contract: Resumable upload streams fixed chunks and recovers offset on 308

`upload` initiates a BigQuery resumable upload session (`uploadType=resumable`), reads the `Location` upload URI, streams payload chunks in multiples of 256 KiB, tracks committed byte offsets across `308 Resume Incomplete` responses, and polls the resulting load `Job` until completion.

## Streaming Row Scanner and Page Prefetch

Slice `5A` optimizes `Row.swift`, `PagedSequence.swift`, `BigQueryClient+TableData.swift`, and `BigQueryClient+Query.swift` with `RowJSONScanner` and `HTTPPagePrefetcher`.

### Contract: RowJSONScanner parses table rows in a single UTF8 pass

`RowJSONScanner` scans raw UTF-8 `tabledata.list` and `jobs.getQueryResults` JSON responses directly into `[Row]` and `nextPageToken` in a single pass without intermediate `Foundation` dictionary or array allocations, falling back to `ProtoJSONDecoder` only if an unexpected wire shape is encountered.

### Contract: HTTPPagePrefetcher buffers one lookahead page concurrently

`HTTPPagePrefetcher` prefetches at most one subsequent page (`nextPageToken`) in a background `Task` while the caller consumes the current page, bounding memory to at most two pages in flight and cancelling any in-flight prefetch task when iteration terminates early.

## Protocol Seam, Documentation, and Integration Tests

Slice `5B` adds `BigQueryProtocol`, package README and DocC documentation, release skill metadata, and the live integration test suite (`Tests/IntegrationTests/**`).

### Contract: BigQueryProtocol exposes complete client surface for test doubles

`BigQueryProtocol` declares all public `BigQueryClient` methods and `BigQueryClient` conforms to `BigQueryProtocol`, allowing downstream applications to inject mock or fake BigQuery clients in unit tests without live network calls.
