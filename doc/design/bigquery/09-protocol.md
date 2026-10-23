# Mock seam, documentation, integration tests, and release

Slice 5B (`feat(bigquery): add protocol, docs, and ITs`, head a19e5f131aaa on
5A) is the integration step. It adds `BigQueryProtocol.swift` and makes
`BigQueryClient` conform, adds `README.md` and the DocC landing article, adds
the live integration test target under `Tests/IntegrationTests`, and lists the
package manifest in the create-release skill. It also adds one unit test to
`Tests/BigQueryClientTests.swift`. No request behavior changes. Flat-doc
sources: [../bigquery.md](../bigquery.md) sections 4.8, 8, 9, 12, and 13
items 10 and 11.

## Mock seam

### Contract

```swift
public protocol BigQueryProtocol: Sendable {
  var projectID: String { get }
  var location: String? { get }
  // Datasets: createDataset, getDataset, listDatasets, updateDataset, deleteDataset
  // Tables: createTable, getTable, listTables, updateTable, deleteTable,
  //   listPartitions, listRows, insertAll([InsertRow], ...)
  // Routines: createRoutine, getRoutine, listRoutines, updateRoutine, deleteRoutine
  // Models: getModel, listModels, updateModel, deleteModel
  // IAM and projects: getIAMPolicy, setIAMPolicy, testIAMPermissions,
  //   getServiceAccount, listProjects
  // Jobs: createJob, runJob, getJob, listJobs, cancelJob, deleteJob, waitForJob,
  //   query(QueryJobConfiguration, ...), query(String, ...), getQueryResults,
  //   dryRun(QueryJobConfiguration, ...), dryRun(String, ...), load
  func getDataset(_ id: DatasetID, view: DatasetView?, accessPolicyVersion: Int32?,
                  selectedFields: [String]?, options: RequestOptions) async throws -> Dataset?
  func query(_ configuration: QueryJobConfiguration, jobID: JobID?, projectID: String?,
             location: String?, timeout: Duration?, options: RequestOptions) async throws -> QueryResult
  …                                            // 40 methods in total
}
public final class BigQueryClient: BigQueryProtocol, Sendable { … }
```

### Shape rules

- Each requirement lists the full parameter list of the matching
  `BigQueryClient` method, with no defaults, and ends with
  `options: RequestOptions`. Return types match the client: `T?` for get, `Bool`
  for delete and cancel, `PagedSequence<T>` for list, `RowSequence` for rows.
- `@discardableResult` is on the create, delete, cancel, `runJob`, and
  `waitForJob` requirements, as on the client.
- Requirements use non-generic value types (`[InsertRow]`, `UploadSource`) and
  no variadic parameters. They cover every public `BigQueryClient` method
  except the generic `insertAll`, which is a protocol extension method.

### Default witnesses

- `projectID` defaults to `""` and `location` to `nil`.
- Every `async throws` requirement throws `GoogleGax.RequestError.unimplemented`.
- Every `PagedSequence` requirement returns
  `PagedSequence { _ in throw GoogleGax.RequestError.unimplemented }`, so the
  error surfaces on the first page fetch, not at the call.
- A test double implements only what it needs. An empty
  `struct EmptyMock: BigQueryProtocol {}` compiles.

### Forwarding overloads

- A second `extension BigQueryProtocol` has 41 `@_disfavoredOverload` methods.
  Each repeats a requirement with the client's default arguments, drops
  `options`, and forwards with `options: .init()`. So `any BigQueryProtocol`
  reads the same as the concrete client.
- The generic
  `insertAll<T: Encodable>(_ values: some Sequence<T>, into:..., options: RequestOptions = .init())`
  maps each value through `InsertRow(_:)` and forwards to the `[InsertRow]`
  requirement. It is the only overload that keeps `options`.
- Defaults match the client, for example `insertIDs: .generateMissing`,
  `chunkSize: 15 << 20`, `deleteContents: false`, `clearing: []`.
- `BigQueryClient`'s own methods keep their default arguments. On the concrete
  type they win over the disfavored overloads.
- A caller of `any BigQueryProtocol` that needs per-call options calls the
  requirement with every argument.

### Notes

- [../bigquery.md](../bigquery.md) section 4.8 puts the generic `insertAll`
  convenience on `BigQueryClient`. The code has it on `BigQueryClient` and also
  in the protocol extension.
- [../bigquery.md](../bigquery.md) section 3 lists `BigQueryProtocol.swift`
  under core. It lands in 5B.

### Tests

- `BigQueryClientTests.protocolDefaultWitnessesThrowUnimplementedAndForwardConvenienceCalls`
  (`// Design: §4.8`): an empty mock reports `""` and `nil`, `getDataset` and
  `listDatasets().collect()` throw `.unimplemented`. A mock that implements
  `getDataset` and `query(_:jobID:projectID:location:timeout:options:)` is
  reached through `getDataset(_:view:)` and `query("SELECT 42", pageSize: 10)`
  on `any BigQueryProtocol`.

## Documentation

### README

`pkgs/swift-google-cloud-bigquery/README.md` (new) has the sections Overview,
Quickstart, Requirements, Installation, Troubleshooting, Contributing, and
License, in the layout of the other package READMEs.

- Overview: use one `BigQueryClient`, Application Default Credentials, project
  from `BigQueryClientOptions.projectID` or `GOOGLE_CLOUD_PROJECT`. Lists are
  lazy `PagedSequence`s. Failures are `BigQueryError`.
- Quickstart: create a dataset and a table, stream rows, query them.
- Installation adds the package from version 0.3.0, then the
  `GoogleCloudBigQuery` target dependency. Issues go to the monorepo.

### DocC

`Sources/GoogleCloudBigQuery/GoogleCloudBigQuery.docc/GoogleCloudBigQuery.md`
(new) is the module landing page.

- Overview: the client, project resolution, dataset-less IDs refer to the
  client's project, rows as an `AsyncSequence` or `RowSequence/decode(_:)`,
  `listRows` and `insertAll`, get -> `nil` and delete -> `false` on 404, other
  failures thrown as `BigQueryError`, retries per `BigQueryRetryPolicy`.
- Topics groups: Essentials (`BigQueryClient`, `BigQueryProtocol`,
  `BigQueryClientOptions`, `BigQueryError`, `BigQueryRetryPolicy`),
  Identifiers, Tables, Views snapshots and clones, External and BigLake tables,
  Rows and schemas, Values, Streaming inserts, Queries, Jobs, Job statistics,
  Datasets, Routines and models, Projects and access control, Pagination.
- A later slice that adds a public type adds it to one Topics group.
- Every public symbol has a doc comment ([../bigquery.md](../bigquery.md)
  section 12). DevRel samples are out of scope.

### Notes

- [../bigquery.md](../bigquery.md) section 12 says core creates the `.docc`
  directory and each slice adds its articles. The code creates it in 5B with
  the landing article only.
- The README names `query(_:parameters:options:)`. The method is
  `query(_:parameters:pageSize:options:)`.

## Integration tests

### Target and gating

- `Package.swift` adds the test target `GoogleCloudBigQueryIntegrationTests`
  at `Tests/IntegrationTests` (dependencies `GoogleCloudBigQuery`,
  `GoogleAuth`, `GoogleGax`, `GoogleCloudBigQueryV2`). The unit target
  `GoogleCloudBigQueryTests` now has `exclude: ["IntegrationTests"]`.
- ITs use `@testable import GoogleCloudBigQuery` (support code calls the
  internal `client.transport`).
- Every suite is `@Suite(.enabled(if: integrationTestsEnabled()))`, true when
  `GOOGLE_CLOUD_PROJECT` is set and non-empty.
- Connection tests also need `BIGQUERY_TEST_CONNECTION_ID`
  (`{location}.{connection}`): `RoutineIntegrationTests.createsRemoteFunction`
  (IT-214) and the BigLake and object table tests in `TableIntegrationTests`.
- Run with the command below ([../bigquery.md](../bigquery.md) section 9).

```sh
env GOOGLE_CLOUD_PROJECT=<project> GOOGLE_CLOUD_SWIFT_LOCAL_DEPS=true \
  swift test --package-path pkgs/swift-google-cloud-bigquery
```

### Support (`Support/IntegrationTestSupport.swift`)

```swift
func integrationTestsEnabled() -> Bool
enum IntegrationTest {
  static var projectID: String?                 // GOOGLE_CLOUD_PROJECT
  static let datasetPrefix = "swift_bq_it_", bucketPrefix = "swift-bq-it-"
  static let label = (key: "swift-bq-it", value: "true")
  static func uniqueName(_ slice: String) -> String        // swift_bq_it_<yyyymmdd>_<slice>_<hex>
  static func uniqueBucketName(_ slice: String) -> String  // swift-bq-it-<yyyymmdd>-<slice>-<hex>
  static func makeClient() throws -> BigQueryClient
  static func withTemporaryDataset<R>(_ client: BigQueryClient, slice: String,
    location: String? = nil, _ body: (DatasetID) async throws -> R) async throws -> R
  static func withTemporaryBucket<R>(slice: String, _ body: (String) async throws -> R) async throws -> R
  static func cleanUpStaleResources(_ client: BigQueryClient) async throws   // janitor
}
```

- Temporary datasets are created with the raw transport, labeled, and deleted
  with `deleteContents=true` whether `body` succeeds or throws. Buckets are
  deleted with their objects the same way.
- The janitor lists datasets filtered by the label and buckets by prefix. It
  deletes only names whose `<yyyymmdd>` stamp is before yesterday (UTC), and
  ignores delete errors.
- `Support/CloudStorage.swift`: the GCS JSON API over the BigQuery transport
  (create, list, delete buckets, upload, download, list, delete objects). It
  avoids a dependency on `swift-google-cloud-storage` and its gRPC build.
- `JobIntegrationSupport.swift` (`enum JobsIT`): sample table, job IDs, SQL
  and column helpers shared by job, query, load, and upload suites.
- Each `@Test` carries `// Baseline: IT-NNN` or `// Design: §N` above it.

### Suites

| File | Tests | Covers |
|---|---|---|
| `CoreIntegrationTests.swift` | 4 | temporary dataset and bucket, service error reasons, janitor |
| `DatasetIntegrationTests.swift` | 20 | datasets, projects, service account |
| `IAMIntegrationTests.swift` | 1 | table IAM |
| `TableIntegrationTests.swift` | 21 | tables, external tables, keys, partitions, `listRows` |
| `ValuesIntegrationTests.swift` | 12 | `insertAll` of every type, query parameters, timestamps, JSON, interval, range |
| `RoutineIntegrationTests.swift` | 8 | routines, remote function |
| `ModelIntegrationTests.swift` | 2 | models |
| `JobIntegrationTests.swift` | 11 | job lifecycle and listing |
| `QueryIntegrationTests.swift` | 21 | fast and slow path, DML, DDL, sessions, scripts, paging |
| `LoadIntegrationTests.swift` | 5 | load jobs from GCS (CSV, Parquet), session tables, flexible column names |
| `UploadIntegrationTests.swift` | 5 | resumable upload |

### Notes

- [../bigquery.md](../bigquery.md) section 9 gives `uniqueName()` as
  `swift_bq_it_<yyyymmdd>_<hex>`. The code adds a slice tag:
  `swift_bq_it_<yyyymmdd>_<slice>_<hex>`.
- Section 9 assigns `IntegrationTestSupport.swift` and
  `CoreIntegrationTests.swift` to core. They land in 5B with every other IT.
- The janitor cutoff is the date stamp, not the resource age. `staleAge` is
  declared but not read.

## Release tooling

- `librarian.yaml` (slice 0B, [02-generated.md](02-generated.md#package-version)) has the
  `google-cloud-bigquery` entry at version `0.3.0`, which generates
  `Sources/GoogleCloudBigQuery/generated/PackageVersion.swift`
  (`PackageVersion.version = "0.3.0"`). Every request sends
  `x-goog-api-client: … gccl/<version>` via
  `GoogleGax._veneerApiClientHeader(packageVersion:)`
  ([03-core.md](03-core.md#transport)).
- 5B adds `pkgs/swift-google-cloud-bigquery/Package.swift` to the
  create-release skill (`.agents/skills/create-release/SKILL.md`): the list of
  hand-written manifests in Step 3, and the `sed` that bumps their `from:`
  versions.
- Before the first release, the `swift-google-cloud-bigquery-v2` repository
  must be published or split. Its remote URL returns 404, so the package
  resolves only with `GOOGLE_CLOUD_SWIFT_LOCAL_DEPS=true`
  ([../bigquery.md](../bigquery.md) section 13 item 11). The README install
  line already pins version 0.3.0.
