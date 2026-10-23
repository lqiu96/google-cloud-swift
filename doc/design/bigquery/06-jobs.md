# Jobs

Slices 4A, 4B and 4C. 4A adds `JobStatus.swift`, `JobStatistics.swift`, `JobConfiguration.swift`,
`LoadJobConfiguration.swift`, `ExtractJobConfiguration.swift` and `CopyJobConfiguration.swift`. 4B
adds `Job.swift`, `QueryJobConfiguration.swift`, `QueryParameter.swift`,
`QueryParameterValue+Factories.swift`, `QueryParameterValue+Convertible.swift` and `QueryResult.swift`.
4C adds `BigQueryClient+Jobs.swift`. Query and upload paths are in [07-query.md](07-query.md). The
flat source is [bigquery.md](../bigquery.md) 4.7 (slice 4), 5.2 and 10.

## Job models

```swift
public struct JobState: RawRepresentable, Sendable, Hashable { pending, running, done }
public struct JobStatus: Sendable, Hashable {
  var state: JobState; var errorResult: BigQueryError.Detail?; var errors: [BigQueryError.Detail]
  var isDone: Bool }                                  // state == .done
public struct Job: Sendable, Equatable {              // 4B, Job.swift
  var id: JobID; var configuration: JobConfiguration?; var status: JobStatus
  var statistics: JobStatistics?; var userEmail, etag, selfLink: String? }
```

- A job can be `.done` and still have failed. Failure is `errorResult != nil`, never the state.
- `JobStatus.failure(jobID:)` (internal, used as `Job.failure`) builds the error every wait path
  throws: `BigQueryError(kind: .job, jobID:)`, message from `errorResult.message` (fallback
  `"The job failed."`), `errors` = `[errorResult]` followed by the other `status.errors`.
- `Job(wire: Job)`: a missing `jobReference` gives `JobID(jobID: "")`, a missing `status` gives
  state `""`, empty strings become `nil`, and an unknown job type gives `configuration == nil`.
- `Job(wire: ListFormatJob)` (`jobs.list`) fills `status.state` and `status.errorResult` from the
  top-level `state` / `errorResult` when `status` lacks them. `etag` and `selfLink` stay `nil`.
- Tests: `JobModelTests.swift` (`JobTests`, `JobStatusTests`).

## Job statistics

```swift
public struct JobStatistics: Sendable, Hashable {
  creationTime, startTime, endTime: Date?; totalBytesProcessed, totalSlotMs: Int64?; completionRatio
  numChildJobs; parentJobID, reservationID: String?; scriptStatistics; transactionInfo; sessionInfo
  query: QueryStatistics?; load: LoadStatistics?; extract: ExtractStatistics?; copy: CopyStatistics? }
public struct QueryStatistics { billingTier; cacheHit; statementType: StatementType?; ddlOperationPerformed
  ddlTargetTable/Routine/Dataset; estimatedBytesProcessed; numDMLAffectedRows; dmlStats: DMLStats?
  exportDataStatistics; referencedTables: [TableID]; referencedRoutines: [RoutineID]; totalBytesBilled
  totalBytesProcessed; totalPartitionsProcessed; totalSlotMs; queryPlan: [QueryStage]
  timeline: [TimelineSample]; schema: Schema?; searchStatistics; metadataCacheStatistics
  undeclaredQueryParameters: [UndeclaredQueryParameter /* name: String?, type: String */] }
// plus SessionInfo, TransactionInfo, ScriptStatistics, StatementType, DMLStats, QueryStage, TimelineSample,
// SearchStatistics, MetadataCacheStatistics, TableMetadataCacheUsage, Load/Extract/CopyStatistics
```

- Output only. Every type has a public memberwise `init` for test doubles and an internal
  `init(wire:)`, with no `.wire` direction.
- Times are epoch milliseconds on the wire. Empty strings, `numChildJobs == 0` and generated
  `*_UNSPECIFIED` enum values (`specifiedEnumValue(_:)`) decode to `nil`.
- Enum-like values (`StatementType`, `EvaluationKind`, `IndexUsageMode`, `UnusedReason`) are
  extensible `RawRepresentable` structs, so unknown wire values survive.
- `referencedTables` keeps dataset-less references (anonymous result tables): `hasDatasetID == false`,
  printed as `p._anon`. See [03-core.md](03-core.md#dataset-less-tableid).
- Tests: `JobModelTests.swift` (`JobStatisticsTests` with
  `queryStatisticsDecodesDatasetLessReferencedTables`, `QueryStageTests`, `DMLStatsTests`,
  `MetadataCacheStatisticsTests`).

## Job configurations

```swift
public enum JobConfiguration: Sendable, Equatable {
  case query(QueryJobConfiguration)                   // added in 4B
  case load(LoadJobConfiguration), extract(ExtractJobConfiguration), copy(CopyJobConfiguration) }
public struct LoadJobConfiguration { destinationTable: TableID; sourceURIs: [String]; format: DataFormat?
  csvOptions, parquetOptions, avroOptions, hivePartitioning; schema; autodetect; dispositions
  schemaUpdateOptions; maxBadRecords; ignoreUnknownValues; partitioning, clustering, destinationEncryption
  referenceFileSchemaURI; decimalTargetTypes; projectionFields; jsonExtension; columnNameCharacterMap
  fileSetSpecType; timeZone and date/time format strings; connectionProperties; createSession
  init(destinationTable: TableID, sourceURIs: [String] = [], format: DataFormat? = nil) }
public struct ExtractJobConfiguration { source: Source /* .table(TableID) | .model(ModelID) */
  destinationURIs; format; compression: ExtractCompression?; printHeader; fieldDelimiter
  useAvroLogicalTypes; modelTrialID; init(source:destinationURIs:format: = nil) }
public struct CopyJobConfiguration { sourceTables: [TableID]; destinationTable: TableID
  operationType: CopyOperationType?; destinationExpirationTime: Date?; dispositions; destinationEncryption
  init(sourceTables:destinationTable:operationType:), init(sourceTable:destinationTable:operationType:) }
// every config also has labels: [String: String], jobTimeout: Duration?, reservation: String?
// RawRepresentable: CreateDisposition, WriteDisposition, SchemaUpdateOption, CopyOperationType,
// ExtractCompression, ColumnNameCharacterMap, JSONExtension, DataFormat.mlTFSavedModel/.mlXGBoostBooster
public struct ConnectionProperty { key, value: String; static func sessionID(_:), timeZone(_:) }
```

- `JobConfiguration` is closed. `init?(wire:)` checks `query`, `load`, `extract`, `copy` in that
  order and returns `nil` for anything else.
- `labels`, `jobTimeout` (`jobTimeoutMs`) and `reservation` live on the shared wire
  `JobConfiguration` (`CommonJobFields`). `.wire` writes them for every case, and `dryRun` only
  for `.query` when `true`.
- `withDefaultProject(_:)` (internal) fills a `nil` project in every table, dataset and model
  reference and never replaces an explicit one. `jobs.insert` and the upload call it with the
  job's project.
- Load CSV options are flattened onto `JobConfigurationLoad`, Avro is only
  `useAvroLogicalTypes`, Parquet and Hive options stay nested. See
  [03-core.md](03-core.md#shared-configurations).
- `fileSetSpecType == FILE_SYSTEM_MATCH` reads back as `nil` (proto3 default). Copy reads one
  source from `sourceTable` or `sourceTables` and always writes `sourceTables`.
- Tests: `JobConfigurationTests.swift` (`Load`, `Extract`, `Copy` and `ConnectionProperty` suites).

### Notes

- At 4A the enum has only `load`, `extract` and `copy`. 4B adds `.query` and `Job`. bigquery.md 4.7
  lists all four cases and `Job` as one unit.

## Query parameters

```swift
public enum QueryParameters: Sendable, Equatable {
  case named([String: QueryParameterValue]), positional([QueryParameterValue]) }
public struct QueryParameterValue: Sendable, Equatable {   // internal: wire type + wire value
  static func string, int64, bool, float64, numeric(Decimal), bigNumeric, bytes(Data), geography(wkt),
    json(text), timestamp(Date | micros: | BigQueryTimestamp), date/time/dateTime/interval(value),
    timestamp/date/time/dateTime/interval(_ text: String) throws, range(BigQueryRange),
    array(_:of: QueryParameterType), array<E: QueryParameterConvertible>([E]),
    struct(KeyValuePairs<String, QueryParameterValue>), struct([(name:, value:)]), null(QueryParameterType)
  var parameterType; var scalarValue: String?; var arrayValues; var structValues; var rangeValue }
public struct QueryParameterType: Sendable, Equatable, CustomStringConvertible {  // GoogleSQL description
  init(_ type: FieldType); static let string ... interval; static func array, struct([StructField]), range
  var typeName: String; var elementType; var structFields; var rangeElementType }
public protocol QueryParameterConvertible { static var queryParameterType; var queryParameterValue }
// String, Bool, Int, Int64, Int32, Double, Float, Decimal, BigNumeric, Data, Date, BigQueryTimestamp,
// BigQueryDate, BigQueryTime, BigQueryDateTime, Interval, Optional (nil -> typed NULL)
```

- Internal contract used by 4B and 4D, do not change: `QueryParameters.wire` (named parameters
  sorted by name) and `QueryParameters.wireMode` (`"NAMED"` / `"POSITIONAL"`).
- `init(wire:mode:) throws` reverses it. `"POSITIONAL"` gives `.positional`, anything else
  `.named`. It throws `DecodingError` for a parameter without a type or a named one without a
  name. Wire type and value are kept verbatim, so every type round-trips.
- `float64` sends `NaN`, `Infinity`, `-Infinity`. `timestamp(Date)` sends
  `YYYY-MM-DD HH:MM:SS.FFFFFF+00:00`. Text factories throw `.invalidArgument` on bad input. Value
  types come from [04-values.md](04-values.md#scalar-types).
- `struct` keeps field order. `null(.array(...))` is an empty array on the server.
  `array(_:of:)` types empty arrays and arrays of structs explicitly.
- Tests: `QueryParameterValueTests.swift`.

### Notes

- bigquery.md 10 has core land the `QueryParameters` shell and seed constructors, and slice 2 add
  the rest. In the code, 4B lands the whole parameter API, including `QueryParameterConvertible`
  and reverse parsing.

## Query job configuration

```swift
public struct QueryJobConfiguration: Sendable, Equatable {
  query: String; parameters: QueryParameters?; defaultDataset: DatasetID?; destinationTable: TableID?
  dispositions; schemaUpdateOptions; userDefinedFunctions; tableDefinitions: [String: ExternalDataConfiguration]
  priority: QueryPriority?; allowLargeResults; flattenResults; useQueryCache; maximumBytesBilled
  destinationEncryption; timePartitioning; rangePartitioning; clustering; scriptOptions: ScriptOptions?
  connectionProperties; createSession; dryRun: Bool; labels; jobTimeout; reservation
  jobCreationMode: JobCreationMode?   // request-only, never stored on the job
  maxResults: Int64?                  // page size of QueryResult.rows, not a LIMIT
  init(_ query: String, parameters: QueryParameters? = nil) }
// QueryPriority { interactive, batch }, KeyResultStatementKind { last, firstSelect },
// ScriptOptions { statementTimeout: Duration?, statementByteBudget: Int64?, keyResultStatement }
```

- GoogleSQL only: `.wire` always sends `useLegacySql = false`.
- Read back from a job, parameters without a `parameterMode` are positional if all are unnamed,
  otherwise named. Unreadable parameters leave `parameters == nil` instead of failing the job
  decode. `dryRun` comes from the shared `JobConfiguration.dryRun`.
- `jobCreationMode` and `maxResults` have no `JobConfigurationQuery` field and are lost in a round
  trip through a job.
- `tableDefinitions` uses [05-resources.md](05-resources.md#external-data-configuration).
  Fast-path eligibility and the `jobs.query` body are in
  [07-query.md](07-query.md#fast-path-allowlist).
- Tests: `JobConfigurationTests.swift` (`QueryJobConfigurationTests`), `JobFixtures.swift`.

## Query result

```swift
public struct QueryResult: Sendable {
  schema: Schema?                 // nil iff no result set (DDL, some scripts)
  totalRows: UInt64?              // result-set rows only, never the DML count
  numDMLAffectedRows: Int64?; dmlStats: DMLStats?; jobID: JobID?; queryID: String?; location: String?
  cacheHit: Bool?; statementType: StatementType?; jobCreationReason: String?
  totalBytesProcessed, totalBytesBilled, totalSlotMs: Int64?
  sessionInfo: SessionInfo?; creationTime, startTime, endTime: Date?
  rows: RowSequence               // empty when schema == nil
  public init(..., rows: RowSequence) }   // all else defaulted, for test doubles
public struct QueryDryRunResult: Sendable, Hashable { schema: Schema?; totalBytesProcessed: Int64?
  referencedTables: [TableID]; undeclaredParameters; statementType; statistics: QueryStatistics? }
```

- `jobID == nil` means a stateless (`JobCreationMode.optional`) query, and `queryID` is set.
- `rows` is a `RowSequence` from [04-values.md](04-values.md#row-sequence). How each path fills
  these fields is in [07-query.md](07-query.md#query-execution).

## Job operations

```swift
func createJob(_ configuration: JobConfiguration, id: JobID? = nil, selectedFields: [String]? = nil,
               options: RequestOptions = .init()) async throws -> Job
func getJob(_ id: JobID, selectedFields: [String]? = nil, options:) async throws -> Job?   // nil on 404
func listJobs(projectID: String? = nil, allUsers: Bool = false, stateFilter: Set<JobState> = [],
              parentJob: JobID? = nil, minCreationTime: Date? = nil, maxCreationTime: Date? = nil,
              selectedFields: [String]? = nil, pageSize: Int? = nil, pageToken: String? = nil,
              options:) -> PagedSequence<Job>
@discardableResult func cancelJob(_ id: JobID, options:) async throws -> Bool   // false on 404
@discardableResult func deleteJob(_ id: JobID, options:) async throws -> Bool   // false on 404
```

- Every `JobID` goes through `resolve(_:)`, so a `nil` project or location uses the client's.
  Paths are `/bigquery/v2/projects/{p}/jobs[/{job}]`, and `location` is a query item when set.
- `createJob` with `id == nil` uses `JobID.random()` and calls the internal
  `insertJob(_:id:generatedID:selectedFields:options:)`, which 07-query.md reuses:
  - `POST .../jobs`, `idempotent: true`, body `{jobReference, configuration}` with
    `withDefaultProject(job project)`.
  - A 2xx job whose `errorResult.reason` is `rateLimitExceeded` or `jobRateLimitExceeded` throws
    `RequestError.jobRateLimited` inside the retry loop with a fresh `JobID.random` (same project
    and location) when the ID was generated. With a caller ID the failed `Job` is returned as is.
  - A 409 is recovered with `getJob(id)` only when an earlier attempt with the same ID was sent in
    this call. A 409 on the first attempt throws `.service` with status 409.
- `selectedFields` adds required fields: `jobs.get` / `jobs.insert` send
  `fields=jobReference,configuration,...`, and `listJobs` sends
  `fields=nextPageToken,jobs(jobReference,configuration,state,errorResult,...)`.
- `listJobs` always sends `projection=full`, one `stateFilter` per state (lowercased, sorted),
  `parentJobId`, `min/maxCreationTime` in epoch milliseconds and `maxResults`.
- `getJob` returns a failed job instead of throwing. `cancelJob` is `POST .../{job}/cancel` and
  `deleteJob` is `DELETE .../{job}/delete`, both via `deleteOrFalse`. A lost-success delete retry
  returns `false`. See [03-core.md](03-core.md#not-found-contract) and
  [03-core.md](03-core.md#retry-policy).
- Tests: `JobClientTests.swift` (`createJob*`, `conflict*`, `jobRateLimit*`, `getJob*`,
  `listJobs*`, `cancelJob*`, `deleteJob*`).

## Waiting for jobs

```swift
@discardableResult func waitForJob(_ id: JobID, timeout: Duration? = nil, options:) async throws -> Job
@discardableResult func runJob(_ configuration: JobConfiguration, id: JobID? = nil,
                               timeout: Duration? = nil, options:) async throws -> Job
```

- `waitForJob` polls `getJob(id, selectedFields: ["status"])` and sleeps
  `options.pollingBackoffPolicy ?? clientOptions.pollingBackoffPolicy` between polls via
  `transport.sleep`. At `DONE` it does one full `getJob`, then throws `job.failure` (`.job`) or
  returns the job.
- No deadline by default. With `timeout`, each sleep is capped at the remaining time and an
  expired deadline throws `BigQueryError(kind: .timeout, jobID:)`. The job is never cancelled.
- A job that disappears (404 on any poll) throws `.service` with status 404, reason `notFound` and
  `jobID`, so `isNotFound` is `true`.
- `runJob` = `createJob` (without `selectedFields`), then it throws at once if the created job
  already failed, returns it if already `DONE`, and otherwise calls `waitForJob`. The timeout
  starts after creation.
- Query waits do not use this loop. They long-poll `getQueryResults`, see
  [07-query.md](07-query.md#query-execution).
- Tests: `JobClientTests.swift` (`waitForJob*`, `runJob*`).
