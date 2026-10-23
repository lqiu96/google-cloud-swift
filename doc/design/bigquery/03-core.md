# BigQuery core: client, transport, IDs, schema

Stack slice 1 (the flat doc's Core slice): commits `34b6fec2a7e4` (core client and transport) and `f6e6a959bd7d` (dataset-less `TableID`). It covers `pkgs/swift-google-cloud-bigquery/Package.swift` and the core files in `Sources/GoogleCloudBigQuery/` and `Tests/`. Every later slice builds on these contracts. Source wording: [bigquery.md](../bigquery.md) sections 3, 4.1 to 4.6, 4.9, 5 and 10. Decisions: [00-overview.md](00-overview.md).

## Package layout

```
Package.swift   tools 6.2, macOS 15, InternalImportsByDefault, NonisolatedNonsendingByDefault, strictMemorySafety
                deps: auth, gax, wkt, bigquery-v2, iam-v1, swift-log, NIOCore, NIOHTTP1
                GOOGLE_CLOUD_SWIFT_LOCAL_DEPS=1|true|<root> switches sibling deps to local paths
Sources/GoogleCloudBigQuery/
  BigQueryClient  BigQueryClientOptions  BigQueryError  BigQueryRetryPolicy  ResourceIDs  JobID
  PagedSequence  Schema  SharedConfigurations (+ UserDefinedFunction)  DataFormat
  Internal/ HTTPTransport  GaxHTTPTransport  BigQueryTransport  RequestBody  ProjectDiscovery
            RowFormat  Wire+Core  Wire+Time
Tests/  BigQueryClientTests  BigQueryTransportTests  CoreHelpersTests  PagedSequenceTests  ResourceIDsTests
        Support/FakeHTTPTransport  Support/WireJSON
```

Only `GoogleGax` (`ClientOptions`, `RequestOptions`, `RetryPolicy`) is a `public import`. `GoogleCloudBigQueryV2`, `GoogleIAMV1` and `GoogleWKT` stay internal, so no generated type appears in a public signature.

### Notes

- bigquery.md section 3 lists `BigQueryProtocol`, `RowSequence`, `Row` (`Row`, `FieldValue`) and the `QueryParameter` shell as core. They are not in this slice, so `Row.rows(from:schema:)` and `RowSequence` from section 10 do not exist yet.
- `Wire+Time.swift` is not in the flat layout. `RowFormat.swift` lands here although section 10 gives it to the Values slice.

## Client and options

```swift
public final class BigQueryClient: Sendable {
  public static let defaultEndpoint = "https://bigquery.googleapis.com"
  public let projectID: String; public let location: String?
  let defaultJobCreationMode: JobCreationMode?; let transport: BigQueryTransport
  public convenience init(_ options: BigQueryClientOptions = .init()) throws
  init(projectID:location: = nil, defaultJobCreationMode: = nil, transport:)   // unit tests
}
public struct BigQueryClientOptions: Sendable {
  public var client: GoogleGax.ClientOptions        // attemptTimeout defaults to .seconds(60)
  public var projectID: String?; var location: String?; var defaultJobCreationMode: JobCreationMode?
  public init(); public func with(_ config: (inout Self) throws -> Void) rethrows -> Self
}
```

- The public init resolves the project ([Project and location resolution](#project-and-location-resolution)), installs `BigQueryRetryPolicy.defaultPolicy` when `client.retryPolicy` is `nil`, and wraps `_HTTPClient(from:withDefaultEndpoint:)` in `GaxHTTPTransport`.
- Assigning a fresh `ClientOptions()` to `client` resets the attempt timeout to the gax default (15 s). Mutate the existing value instead.
- Every RPC method a slice adds ends with `options: GoogleGax.RequestOptions = .init()`.
- Tests: `BigQueryClientTests`.

### Notes

- `defaultJobCreationMode` is internal on the client. bigquery.md 4.1 does not list it on the client.

## Resource IDs

```swift
public struct DatasetID: Sendable, Hashable, CustomStringConvertible {
  public var projectID: String?; public var datasetID: String      // nil project -> client project
  public init(projectID: String? = nil, datasetID: String)
  public init(_ string: String) throws                             // "d", "p.d", "p:d"
  public func table(_:) -> TableID; func routine(_:) -> RoutineID; func model(_:) -> ModelID
}
public struct TableID   { projectID?, datasetID, tableID; init(projectID:datasetID:tableID:),
                          init(dataset:tableID:), init(_ "d.t" | "p.d.t" | "p:d.t") throws,
                          var dataset: DatasetID; var hasDatasetID: Bool; var iamResourceName (internal) }
public struct RoutineID { projectID?, datasetID, routineID; same shape, var dataset }
public struct ModelID   { projectID?, datasetID, modelID;   same shape, var dataset }
public struct JobID     { projectID?, jobID: String, location: String?; init(projectID:jobID:location:)
                          static func random(prefix: = "", projectID: = nil, location: = nil) -> JobID }
```

- Parsing: the last `count` dot components are dataset (and table) and anything before them is the project, so `example.com:p.d.t` has project `example.com:p`. The legacy form applies when exactly `count` components follow the last colon (`p:d.t`, `example.com:p:d.t`). Empty components, an empty legacy project or too few components throw `.invalidArgument` (`invalid <kind> ID: "<string>"`).
- `description` is Standard SQL `project.dataset.table` with empty components dropped. `JobID.description` is the `bq` form `project:location.job`. `JobID.random` appends a lowercased UUID to `prefix`.
- `iamResourceName` is `projects/p/datasets/d/tables/t` and needs a resolved project.

### Dataset-less TableID

Query job statistics and anonymous temporary tables may carry a table reference without a dataset. Contract from `f6e6a959bd7d`:

- `hasDatasetID == !datasetID.isEmpty`. Consumers check it before using `dataset` or building a dataset-scoped path.
- `description` omits the empty dataset: `TableID(projectID: "p", datasetID: "", tableID: "_anon")` -> `p._anon`, without a project -> `_anon`. A full ID still prints `p.d.t`.
- The string parser still rejects dataset-less input (`TableID("t")` throws). Such IDs only come from `TableID(wire:)` or the memberwise init.
- Tests: `ResourceIDsTests` (`TableIDTests.datasetLessTableIDFormattingAndContract`, plus Dataset, Routine, Model and Job ID suites).

### Notes

- bigquery.md 4.2 names the accessor `datasetReference`. The code uses `dataset` and adds `hasDatasetID`. The empty-component filter in `joinResourcePath` applies to every ID type.

## Errors

```swift
public struct BigQueryError: Error, Sendable, Hashable, CustomStringConvertible {
  public struct Kind: Sendable, Hashable, CustomStringConvertible { service, job, invalidArgument, timeout }
  public struct Detail: Sendable, Hashable { reason, location, message, debugInfo: String? }
  public var kind: Kind; var message: String; var httpStatusCode: Int?; var status: String?
  public var errors: [Detail]; var jobID: JobID?
  public var reason: String? { get }; var location: String? { get }   // from errors.first
  public var isNotFound: Bool { get }       // httpStatusCode == 404 || reason == "notFound"
  public init(kind:message:httpStatusCode: = nil, status: = nil, errors: = [], jobID: = nil)
}
// internal: static func invalidArgument(_:), init(httpStatusCode:payload:) -> .service,
//           init?(job: JobID?, errorResult: ErrorProto?, errors: [ErrorProto]) -> .job, var isHTTPNotFound
```

- `.service`: parsed from `{"error":{code,message,status,errors[]}}`. An unparsable body becomes the message verbatim, an empty body becomes `HTTP <code>`.
- `.job`: `errorResult` first, then `errors` without duplicates. Message is the first detail's message, else its reason, else `job failed`. Returns `nil` when there is no error.
- `.invalidArgument` is client-side validation. `.timeout` is a wait deadline with `jobID` set (Jobs slice).
- `description`: `BigQueryError(<kind>[, http N][, reason: R][, job: J]): <message>`.
- Transport, auth and non-HTTP exhaustion errors stay `GoogleGax.RequestError`. Cancellation stays `CancellationError`.
- Tests: `BigQueryTransportTests.swift` suite `BigQueryErrorTests`.

## Transport

```swift
enum HTTPMethod: String { get, post, put, patch, delete }
struct HTTPRequest { method; target: Target /* .path(percent-encoded) | .url(absolute) */; query: [URLQueryItem]
                     headers: [String: String]; body: Data?; options: RequestOptions
                     init(method:path:...), init(method:url:...); static func encode(segment:) -> String }
struct HTTPResponse { statusCode; headers /* lowercased */; body: Data; func header(_:) -> String? }
protocol HTTPTransport: Sendable { func send(_: HTTPRequest, timeout: Duration?) async throws -> HTTPResponse }
struct BigQueryTransport {
  let http: any HTTPTransport; let clientOptions: ClientOptions
  func json<R>(_: HTTPRequest, idempotent: Bool) async throws -> R
  func jsonOrNil<R>(_: HTTPRequest, as: R.Type, idempotent: Bool = true) async throws -> R?
  func deleteOrFalse(_: HTTPRequest, idempotent: Bool = true) async throws -> Bool
  func send(_: HTTPRequest, idempotent: Bool) async throws -> HTTPResponse          // 2xx only
  func json<R>(idempotent:options:request: (_ attempt: Int) throws -> HTTPRequest,
               validate: (R) throws -> Void = { _ in }) async throws -> R
  func sendOnce(_: HTTPRequest) async throws -> HTTPResponse                         // one attempt, any status
}
```

- Every request gets `x-goog-api-client` (`gl-swift/... gccl/<PackageVersion>`). Path requests also get `prettyPrint=false` unless present. Absolute URLs get no extra query items.
- Each attempt turns a non-2xx status into `RequestError.http(HTTPDetails)` so any `RetryPolicy` can classify it. Other non-gax errors become `RequestError.io`.
- 2xx bodies decode with `_ProtoJSONDecoder`, an empty body as `{}`. A decode failure is `RequestError.malformedResponse` and is not retried.
- `encode(segment:)` keeps RFC 3986 unreserved characters only. `GaxHTTPTransport` uses a 60 s attempt timeout when neither request nor client sets one.
- Test seam: `FakeHTTPTransport` (`enqueue`, `enqueueError`, `requests`, `timeouts`, `client()`, `transport()`) and `HTTPRequest.path`, `queryValue(_:)`, `jsonBody()`. Pinned by `BigQueryTransportTests`.

### Notes

- bigquery.md 5.1 says a 204 or empty body is never decoded. In the code `json` decodes an empty body as an empty message. Only `send` and `deleteOrFalse` skip decoding.

## Retry policy

```swift
public struct BigQueryRetryPolicy: RetryPolicy, Sendable, Equatable {
  public init()                                      // BigQueryRetryErrors().retryOnIO().strictIdempotency()
  public static func unbounded() -> BigQueryRetryPolicy
  public static var defaultPolicy: some RetryPolicy  // unbounded().withTimeLimit(.seconds(50)).withAttemptLimit(6)
}
extension RequestError { static func jobRateLimited(_ errors: [ErrorProto]) -> RequestError }  // internal
```

- Retryable: HTTP 429, 500, 502, 503, 504, any `error.errors[].reason` in `rateLimitExceeded`, `backendError`, `internalError`, `badGateway` (any status), or an I/O error. Only idempotent calls retry.
- `json(idempotent:options:request:validate:)` numbers attempts from 1 so a slice can mint a fresh `requestId` or `JobID`. `validate` throws `jobRateLimited` for a 2xx job-level rate limit: a synthetic 429 `RESOURCE_EXHAUSTED` that keeps the original details on exhaustion.
- Exhaustion is unwrapped: a final `.http`, or `.exhausted(.elapsedTime(source: .http))`, maps to `BigQueryError(.service)`. Other exhaustion stays a `RequestError`.
- Per-call `RequestOptions.retryPolicy` overrides the client default. Each slice decides idempotency per the table in [bigquery.md 5.2](../bigquery.md#52-retry-policy).
- Tests: `BigQueryRetryPolicyTests` and the retry cases in `BigQueryTransportTests` (six-attempt default, attempt and elapsed-time exhaustion, per-attempt validation, per-call override).

## Not found contract

| Helper | On HTTP 404 |
| ------ | ----------- |
| `jsonOrNil` (for `get*`) | returns `nil` |
| `deleteOrFalse` (for `delete*`, `cancelJob`) | returns `false` |
| `json`, `send` | throws `BigQueryError(.service)` with `isNotFound == true` |

- Only `.service` with status 404 (`isHTTPNotFound`) is swallowed. A `.job` error whose reason is `notFound` still throws.
- A retried DELETE whose first attempt succeeded but lost its response sees 404 and returns `false`.
- Tests: `jsonOrNilReturnsNilOnNotFound`, `jsonOrNilThrowsOtherErrors`, `deleteOrFalseMapsNotFound`.

## Request bodies

```swift
enum JSONOverride: Sendable, Equatable { case null; case value(WKTValue) }
enum RequestBody {
  static func json(_ wire: some Encodable, setting: [String: JSONOverride] = [:], omitting: [String] = []) throws -> Data
  static func json(_ wire: some Encodable, settingPaths: [[String]: JSONOverride], omitting: [String] = []) throws -> Data
}
```

- Encodes with `_ProtoJSONEncoder` (omits `nil` and empty collections, drops `omitting` paths), then writes each override at its dot path (`setting`) or segment path (`settingPaths`, for keys containing `.`), creating intermediate objects. With overrides the output has sorted keys.
- PATCH: property `nil` -> key omitted, non-`nil` -> key present, clear -> `.null` at the path. Slices own the clearable `Field` types and `ifMatch` ([bigquery.md 5.4](../bigquery.md#54-request-bodies-and-patch-semantics)).
- Tests: `CoreHelpersTests.swift` suite `RequestBodyTests`.

## Pagination

```swift
public struct Page<Element: Sendable>: Sendable { var items: [Element]; var nextPageToken: String?; init(items:nextPageToken: = nil) }
public struct PagedSequence<Element: Sendable>: AsyncSequence, Sendable {
  public typealias Fetch = @Sendable (_ pageToken: String?) async throws -> Page<Element>
  public init(fetch: @escaping Fetch)
  public init(firstPage: Page<Element>, fetch: @escaping Fetch)   // first page not refetched
  public init(_ items: [Element])                                  // test doubles
  public var pages: Pages { get }; public func collect() async throws -> [Element]
}
```

- Lazy until iterated. Empty intermediate pages are skipped. A `nil` or empty token ends the sequence. Slices route each fetch through the retry loop and also take `pageToken: String? = nil` on list methods.
- gax's `PaginatedResponseSequence` is SPI and cannot start from a fetched first page, so it is not reused.
- Tests: `PagedSequenceTests`.

## Schema

```swift
public struct Schema: Sendable, Hashable, ExpressibleByArrayLiteral {
  public var fields: [Field]; public init(_ fields: [Field])
  public func index(of name: String) -> Int?; public subscript(name: String) -> Field?
  var childSchemas: [Schema?]; var hasTimestamp: Bool              // internal, rebuilt when fields change
}
public struct Field: Sendable, Hashable {
  name; type: FieldType; mode: Mode? /* nil = NULLABLE */; fields: [Field]; description, collation,
  defaultValueExpression: String?; maxLength, precision, scale, timestampPrecision: Int64?
  roundingMode: RoundingMode?; rangeElementType: FieldType?; policyTags: [String]?
  public init(_ name:, _ type:, mode: = nil, fields: = [], description: = nil)
  struct Mode { nullable, required, repeated }; struct RoundingMode { roundHalfAwayFromZero, roundHalfEven }
}
public struct FieldType: RawRepresentable { string, bytes, int64, float64, numeric, bigNumeric, bool, timestamp,
                                            date, time, dateTime, geography, json, interval, range, `struct` }
```

- `index(of:)` matches exactly, then case-insensitively. The first duplicate wins. Equality and hashing use `fields` only.
- `FieldType(rawValue:)` uppercases and maps `INTEGER`->`INT64`, `FLOAT`->`FLOAT64`, `BOOLEAN`->`BOOL`, `RECORD`->`STRUCT`, `DECIMAL`->`NUMERIC`, `BIGDECIMAL`->`BIGNUMERIC`.
- `hasTimestamp` covers `TIMESTAMP`, `RANGE` of `TIMESTAMP` or unknown element, and nested fields. `RowFormat.queryItems(for:)` drops `formatOptions.timestampOutputFormat=ISO8601_STRING` only for a known schema without timestamps. `RowFormat.formatOptions` is the `jobs.query` form.

### Notes

- Cell parsing (`Row`, `FieldValue`) from bigquery.md 4.5 is not in this slice.

## Shared configurations

```swift
public struct EncryptionConfiguration { kmsKeyName: String? }
public struct TimePartitioning { type: PartitionType /* .hour .day .month .year, extensible */; field: String?; expiration: Duration? }
public struct RangePartitioning { field: String; range: Range { start, end, interval: Int64 } }
public struct Clustering { fields: [String] }
public struct JobCreationMode: RawRepresentable { required, optional }      // JOB_CREATION_*
public enum UserDefinedFunction { case inline(String), fromURI(String) }
public struct DataFormat: RawRepresentable { csv, json /* NEWLINE_DELIMITED_JSON */, avro, parquet, orc,
                                             datastoreBackup, googleSheets, bigtable, iceberg }
public struct CSVOptions, ParquetOptions, AvroOptions, HivePartitioningOptions   // fields as bigquery.md 4.6
```

- All are `Sendable, Hashable` with public memberwise inits. Format option types have no core wire conversion. Each consumer writes its own (CSV nested for external tables, flattened for load jobs).
- Tests: `CoreHelpersTests.swift` suite `SharedConfigurationsTests`.

### Notes

- `TimePartitioning.requirePartitionFilter` from bigquery.md 4.6 does not exist in the code.

## Project and location resolution

- Project order: `options.projectID`, `GOOGLE_CLOUD_PROJECT`, `GCLOUD_PROJECT`, `project_id` in the file named by `GOOGLE_APPLICATION_CREDENTIALS`. Empty values are skipped. With none, `init` throws `.invalidArgument`. App Engine, gcloud config and metadata server are follow-ups.
- `client.resolve(_:)` for `DatasetID`, `TableID`, `RoutineID`, `ModelID` fills a `nil` or empty project. For `JobID` it also fills a `nil` or empty location from `client.location`. Datasets never inherit the client location.
- Tests: `ProjectDiscoveryTests`, `BigQueryClientTests.resolveFillsMissingProjectAndLocation`, each ID suite's `clientFillsMissingProject`.

## Wire conversions

```swift
extension DatasetID { init(wire: DatasetReference); var wire }   // same for TableID, RoutineID, ModelID, JobID
extension Schema { init(wire: TableSchema); var wire }           // Field likewise
extension EncryptionConfiguration, TimePartitioning, RangePartitioning, Clustering { init(wire:); var wire }
extension UserDefinedFunction { init?(wire: UserDefinedFunctionResource); var wire }   // nil when neither set
extension Duration { var wholeMilliseconds: Int64 }              // truncates toward zero
extension Date { init?(millisecondsSinceEpoch:) /* nil for 0 */; var millisecondsSinceEpoch; init(wire: WKTTimestamp) }
extension WKTTimestamp { init(date: Date) throws }               // truncated to microseconds
```

- IDs: an empty wire `projectId` decodes to `nil` and `nil` encodes as `""`. `JobID` keeps `location`.
- `Field(wire:)`: empty `mode`, zero `maxLength`/`precision`/`scale` and `roundingMode` `UNSPECIFIED` become `nil`.
- `TimePartitioning(wire:)`: empty `type` means `.day` (Java `fromPb`), `expirationMs` <-> `Duration`. `RangePartitioning` bounds travel as decimal strings.
- Tests: `ResourceIDsTests` (`wireRoundTrip`), `SharedConfigurationsTests` (round trips, `durationWholeMilliseconds`, `millisecondsSinceEpochConversions`, `timestampConversions`). Fixtures use `WireJSON.decode` / `object`.
