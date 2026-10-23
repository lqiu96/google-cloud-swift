# Query and upload

Slices 4D and 4E. 4D adds `BigQueryClient+Query.swift` (fast and slow query paths,
`getQueryResults`, dry runs). 4E adds `BigQueryClient+Upload.swift` and `UploadSource.swift`
(resumable upload into a load job). Both build on the models and `insertJob` in
[06-jobs.md](06-jobs.md). The flat source is [bigquery.md](../bigquery.md) 4.7 (slice 4), 5.2
and 6.1 to 6.4.

## Query execution

```swift
func query(_ sql: String, parameters: QueryParameters? = nil, pageSize: Int? = nil,
           options: RequestOptions = .init()) async throws -> QueryResult   // pageSize -> maxResults
func query(_ configuration: QueryJobConfiguration, jobID: JobID? = nil, projectID: String? = nil,
           location: String? = nil, timeout: Duration? = nil, options:) async throws -> QueryResult
func getQueryResults(_ job: JobID, startIndex: UInt64? = nil, pageSize: Int? = nil,
                     options:) async throws -> QueryResult
```

1. `configuration.dryRun == true` throws `.invalidArgument` before any request.
2. `jobID == nil` and [fast-path eligible](#fast-path-allowlist) -> fast path with
   `projectID ?? client.projectID` and `location ?? client.location`.
3. Otherwise slow path: `id = resolve(jobID ?? JobID.random(projectID:location:))`, then
   `insertJob(.query(configuration), generatedID: jobID == nil)` (see
   [06-jobs.md](06-jobs.md#job-operations)). A created job that already failed throws `.job`.
   An explicit `jobID` ignores `projectID` and `location`.

### Fast path (`jobs.query`)

- `POST /bigquery/v2/projects/{p}/queries`, `idempotent: true`. Body: `query`,
  `requestId` (UUID), `useLegacySql=false`, `formatOptions.timestampOutputFormat=ISO8601_STRING`,
  `location`, `jobCreationMode` (`configuration.jobCreationMode ?? client.defaultJobCreationMode`,
  omitted when `nil`), `timeoutMs` only when `timeout` is set (clamped to `UInt32`), `maxResults`,
  `defaultDataset` (project filled from the request project), and the allowlisted fields.
- Transport retries reuse the `requestId`. A 2xx response whose `errors` carry
  `rateLimitExceeded` or `jobRateLimitExceeded` throws `RequestError.jobRateLimited` inside the
  retry loop, and the next attempt uses a fresh `requestId`.
- Any other `errors` in a 2xx response throw `BigQueryError(kind: .job, jobID: jobReference)`.
- `jobComplete != true`: a missing `jobReference` throws `RequestError.malformedResponse`.
  Otherwise the query continues as a job (`completedQuery`, below) and only
  `jobCreationReason` is taken from the `jobs.query` response.
- `jobComplete` with no `schema` and a `jobReference` (DDL, scripts): one `getQueryResults`
  without `timeoutMs` supplies the final page. Still no schema -> `schema == nil`, empty `rows`.
- Metadata comes from the `QueryResponse`: `cacheHit`, `statementType`, byte and slot counts,
  `numDMLAffectedRows`, `dmlStats`, `sessionInfo`, `jobCreationReason` (`*_UNSPECIFIED` -> `nil`),
  `queryID`, times, and `location` (`response.location ?? jobReference.location`).
- Later pages come from `getQueryResults` on the job. A stateless response
  (`jobReference == nil`) with a `pageToken` throws `RequestError.malformedResponse`.

### Slow path and `getQueryResults`

- `waitForQueryResults` long-polls `GET .../queries/{job}` with `timeoutMs = min(10 s, remaining)`
  until `jobComplete`. An expired deadline throws `.timeout` with the `jobID`, and the job is not
  cancelled. A `.service` error from a poll is replaced by the job's own failure when `jobs.get`
  shows one. `errors` in a poll response throw `.job`.
- The query paths and public `getQueryResults` without `startIndex` / `pageSize` poll with
  `maxResults=0`. Public `getQueryResults` has no deadline.
- After completion one full `jobs.get` runs. 404 -> `.service` `isNotFound`. A failed job throws
  `.job`. `schema = page.schema ?? statistics.query.schema`.
- Rows: `totalRows == 0` or no schema -> empty `rows`. If the job has
  `configuration.query.destinationTable` and the polled page has no rows, rows come from
  `listRows(in: destinationTable, schema:)` ([05-resources.md](05-resources.md#table-data)).
  Otherwise the first page is a `getQueryResults` call and later pages use `tabledata.list` on
  the destination table when known, else `getQueryResults`.
- Metadata comes from `Job.statistics.query`, falling back to job-level statistics or the page.
  `location` is `job.id.location`.
- `getQueryResults` and `tabledata.list` send `formatOptions.timestampOutputFormat=ISO8601_STRING`
  unless the schema is known and has no `TIMESTAMP` column.

### Errors

- `queryFailure` maps a `.service` error from `jobs.query` or `jobs.insert` with HTTP 400, 403,
  404 or 409 and no retryable reason to `.job` (`jobID` = the error's, else the slow-path ID).
  So a query failure has kind `.job` on both paths. 401 and exhausted retries stay `.service`.
- Tests: `QueryClientTests.swift` (`fastPath*`, `statelessQuery*`, `incompleteFastPath*`,
  `completeFastPathWithoutSchema*`, `slowPath*`, `queryTimeout*`, `getQueryResults*`,
  `failedQueryReportsTheJobError`, `authenticationFailureStaysAServiceError`,
  `exhaustedRetriesStayAServiceError`, `sqlQueryConvenienceForwardsPageSize`).

### Notes

- bigquery.md 6.1 step 4 says the final poll gives the first page and later pages come from
  `getQueryResults`. The code polls with `maxResults=0`, then reads rows from `tabledata.list` on
  the job's destination table when it has one, or from a separate `getQueryResults` page.
- bigquery.md 6.1 says an incomplete fast-path response polls `getQueryResults`. The code also
  runs `jobs.get`, and the metadata then comes from job statistics, not the `QueryResponse`.

## Fast-path allowlist

```swift
extension QueryJobConfiguration {
  var isFastPathEligible: Bool      // internal
  func queryRequest(requestID:location:jobCreationMode:timeout:defaultProject:) -> QueryRequest
}
```

- Eligibility copies only the allowed fields onto a fresh `QueryJobConfiguration` and compares
  it with `==`. A field added later is therefore slow-path by default.
- Allowed: `query`, `parameters` (named or positional), `defaultDataset`, `useQueryCache`,
  `maximumBytesBilled`, `connectionProperties`, `createSession`, `labels`, `jobTimeout`,
  `reservation`, `jobCreationMode`, `maxResults`. `dryRun` must be `false`.
- Anything else forces the slow path, for example `destinationTable`, dispositions,
  `schemaUpdateOptions`, UDFs, `tableDefinitions`, `priority`, `allowLargeResults`,
  `flattenResults`, encryption, partitioning, clustering, `scriptOptions`.
- An explicit `jobID` always forces the slow path. `JobCreationMode.required` still uses
  `jobs.query`.
- Tests: `QueryClientTests.swift` (`fastPathEligibility`, `queryRequestCarriesTheConfiguration`,
  `requiredJobCreationStillUsesJobsQuery`, `clientDefaultJobCreationModeApplies`,
  `everyQueryRequestAsksForISO8601Timestamps`).

### Notes

- bigquery.md 6.2 lists `location` as an allowlisted configuration field. The code has no
  `location` on `QueryJobConfiguration`. Location is a `query(_:jobID:projectID:location:...)`
  parameter on both paths.

## Dry run

```swift
func dryRun(_ configuration: QueryJobConfiguration, projectID: String? = nil, location: String? = nil,
            options:) async throws -> QueryDryRunResult
func dryRun(_ sql: String, parameters: QueryParameters? = nil, options:) async throws -> QueryDryRunResult
```

- Always `jobs.insert` with `configuration.dryRun = true` (the caller's value is ignored) and a
  generated `JobID.random(projectID:location:)`, through `insertJob(generatedID: true)`. Never
  `jobs.query`.
- Errors are not passed through `queryFailure`: an invalid query keeps kind `.service`. A
  returned job with `errorResult` throws `.job`.
- `QueryDryRunResult` comes from `statistics.query`: `schema`, `totalBytesProcessed`
  (query-level, else job-level), `referencedTables`, `undeclaredParameters`, `statementType`, and
  the full `statistics`.
- `query(_:)` rejects a dry-run configuration with `.invalidArgument`.
- Tests: `QueryClientTests.swift` (`queryRejectsDryRun`, `dryRunReturnsStatistics`,
  `sqlDryRunConvenienceSendsDryRunWithParameters`).

## Resumable upload

```swift
func load(_ source: UploadSource, configuration: LoadJobConfiguration, jobID: JobID? = nil,
          chunkSize: Int = 15 << 20, options:) async throws -> Job   // returns once the job exists
```

1. `id = resolve(jobID ?? JobID.random())`. `chunkSize` is rounded down to a multiple of
   256 KiB, at least 256 KiB. The source is opened before any request.
2. Session: `POST /upload/bigquery/v2/projects/{p}/jobs?uploadType=resumable` with the Job JSON
   (`withDefaultProject(p)`), `Content-Type: application/json; charset=UTF-8` and
   `X-Upload-Content-Type: application/octet-stream`. Sent with `transport.send(idempotent: true)`,
   so the standard retry loop applies. No job-level rate-limit or 409 recovery. A missing
   `Location` header throws `RequestError.malformedResponse`.
3. Chunks: `PUT {Location}` via `transport.sendOnce`, `Content-Range: bytes a-b/*` for non-final
   chunks and `bytes a-b/N` for the last. 308 means "more data": the `Range: bytes=0-N` header
   gives the committed count (no header -> 0). A partial commit resends the rest of the chunk.
4. 200 or 201 finishes the upload, and its body is the `Job`. A final chunk that gets 308 with
   every byte committed throws `RequestError.malformedResponse`.
5. Zero bytes: one finalizing `PUT` with `Content-Range: bytes */0`.
6. Resume: on `RequestError.io`, HTTP 408, 429, 500, 502, 503, 504, or a retryable reason, the
   client sleeps `1 << min(failures - 1, 5)` seconds, queries status with an empty
   `PUT` (`Content-Range: bytes */{N or *}`), and resends from the committed offset. A status
   reply of 200/201 returns the job. Six consecutive failures per chunk rethrow the last error.
   Other statuses throw `BigQueryError(httpStatusCode:payload:)` (`.service`) at once.
7. A committed count outside the current chunk throws `RequestError.malformedResponse`.

- `configuration.sourceURIs` is sent as set (the doc comment says it is ignored).
- Tests: `UploadTests.swift` (`BigQueryClientUploadTests`: `loadOpensASession*`,
  `sessionOpen*`, `chunks*`, `exactMultiple*`, `emptyUpload*`, `retryableChunkError*`,
  `ioError*`, `statusQuery*`, `uploadGivesUpAfterSixFailures`, `partialCommit*`,
  `rangeOutsideTheChunkIsMalformed`, `rateLimitReason*`, `finalChunkReturning308*`).

### Notes

- bigquery.md 6.4 says resume on "5xx". The code resumes only on 500, 502, 503 and 504 (plus 408,
  429 and retryable reasons), and other 5xx statuses fail at once.

## Upload sources

```swift
public struct UploadSource: Sendable {
  static func data(_ data: Data) -> UploadSource
  static func file(_ url: URL) -> UploadSource            // a file: URL
  static func stream<S: AsyncSequence & Sendable>(_ sequence: S) -> UploadSource where S.Element == Data
}
```

- The set of sources is closed (internal `Storage` enum). `UploadReader` (internal) reads them in
  fixed-size chunks.
- `.data` slices the buffer directly. `.file` opens a `FileHandle` in `UploadReader.init`, so a
  missing file throws before a session opens, and the handle closes when `load` returns.
- `.stream` makes a fresh iterator per upload. Empty pieces are skipped, large pieces are split
  across chunks.
- The reader reads one byte past the chunk size to detect the last chunk, so the final `PUT`
  always carries the total size.
- Tests: `UploadTests.swift` (`UploadSourceTests`: `fileSourceUploadsTheFileContents`,
  `missingFileFailsBeforeOpeningASession`, `streamSourceConcatenatesPiecesAndSkipsEmptyOnes`,
  `readerSplitsLargeStreamPiecesIntoChunks`).
