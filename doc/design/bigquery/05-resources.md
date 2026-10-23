# Resources: datasets, projects, IAM, tables, table data, routines, models

Slices 3A (datasets, projects, table IAM), 3B (tables, external data), 3C (table data, streaming inserts), and 3D (routines, models). Sources: the `BigQueryClient+{Datasets,Projects,IAM,Tables,TableData,InsertAll,Routines,Models}.swift` extensions and the models `Dataset`, `Acl`, `IAMPolicy`, `Project`, `Table`, `TableDefinitions`, `TableConstraints`, `ExternalDataConfiguration`, `InsertRow`, `InsertRowEncoder`, `InsertAllResponse`, `Routine`, `Model`, with their `+Wire` files, under `pkgs/swift-google-cloud-bigquery/Sources/GoogleCloudBigQuery`. Flat-doc source: [bigquery.md](../bigquery.md) 4.7, 5.3, 5.4, and 7.

## Datasets

### Rules shared by all resources

- IDs with a `nil` project resolve to the client project before the path `/bigquery/v2/projects/{p}/datasets/{d}[/tables|routines|models/{x}]` is built. Segments use `HTTPRequest.encode(segment:)`. Requests go through `BigQueryTransport` ([03-core.md](03-core.md#transport)).
- `selectedFields` -> `fields=<required>,<selected>`, deduplicated. `nil` sends no `fields`. Required: `datasetReference`, `tableReference,type`, `routineReference`, `modelReference`.
- `list*` sends `maxResults` and `pageToken`. The caller's `pageToken` starts the first page only, an empty `nextPageToken` ends the sequence, and `options` apply to every page.
- Retries: GET, list, and DELETE are idempotent. `*.insert` is never retried (a lost success would get 409). PATCH and PUT are retried only with `ifMatch:`, which sends `If-Match` (mismatch -> HTTP 412).
- 404: `getDataset`, `getTable`, `getRoutine`, `getModel` return `nil` (`transport.jsonOrNil`). `delete*` return `false` (`transport.deleteOrFalse`), also after a lost-success retry. Every other call throws `.service` with `isNotFound` ([bigquery.md](../bigquery.md) 5.3).
- Bodies use `RequestBody.json(wire, settingPaths:, omitting:)`. Unset proto3 scalars and output-only fields are omitted. A clearable `Field` is a JSON path in segments (a key may contain `.`), sent as explicit `null`, and wins over a set value. Empty collections are omitted, so `labels = [:]` changes nothing. Clear with `.labels`.
- On read, proto3 defaults (`""`, `0`, `*_UNSPECIFIED`, empty maps) become `nil`. Times are epoch milliseconds.

### API

```swift
public struct Dataset: Sendable, Hashable {
  var id: DatasetID; friendlyName, description, location: String?; labels: [String: String]?
  defaultTableExpiration, defaultPartitionExpiration: Duration?        // *Ms on the wire
  access: [Acl]?; defaultEncryptionConfiguration: EncryptionConfiguration?; defaultCollation: String?
  maxTimeTravelHours: Int64?; storageBillingModel: StorageBillingModel? { logical, physical }; isCaseInsensitive: Bool?
  resourceTags: [String: String]?; externalDatasetReference: ExternalDatasetReference? { externalSource, connection }
  /* output */ etag, generatedID, selfLink: String?; creationTime, lastModifiedTime: Date?
  struct Field { friendlyName, description, defaultTableExpiration, defaultPartitionExpiration,
                 defaultEncryptionConfiguration, defaultCollation, labels, resourceTags; label(_:), resourceTag(_:) }
}
public struct DatasetView: RawRepresentable { metadata, acl, full }
public struct DatasetUpdateMode: RawRepresentable { updateMetadata, updateACL, updateFull }
public struct Acl { entity: Entity; role: Role? { reader, writer, owner }; condition: Expr?; init(_ entity:, role:, condition:) }
//   Entity: .user .group .domain .specialGroup .iamMember (String), .view(TableID), .routine(RoutineID),
//   .dataset(DatasetID, targetTypes: [TargetType { views, routines }]), .projectOwners ...; one optional accessor per kind

@discardableResult func createDataset(_ dataset: Dataset, accessPolicyVersion: Int32? = nil,
                                      selectedFields: [String]? = nil, options:) async throws -> Dataset
func getDataset(_ id: DatasetID, view: DatasetView? = nil, accessPolicyVersion: Int32? = nil,
                selectedFields: [String]? = nil, options:) async throws -> Dataset?
func listDatasets(projectID: String? = nil, all: Bool = false, filter: String? = nil,
                  pageSize: Int? = nil, pageToken: String? = nil, options:) -> PagedSequence<Dataset>
func updateDataset(_ dataset: Dataset, clearing: Set<Dataset.Field> = [], updateMode: DatasetUpdateMode? = nil,
                   accessPolicyVersion: Int32? = nil, selectedFields: [String]? = nil,
                   ifMatch etag: String? = nil, options:) async throws -> Dataset          // PATCH
@discardableResult func deleteDataset(_ id: DatasetID, deleteContents: Bool = false, options:) async throws -> Bool
```

- Create and update fill the project in the ID and in `view`, `routine`, and `dataset` access entries whose project is `nil` or empty.
- `accessPolicyVersion`, `datasetView`, `updateMode`, `filter`, `all=true`, `deleteContents=true`, `location`, and `storageBillingModel` are sent only when set. A dataset never inherits the client location.
- On update, `labels` merge into the existing keys and `access` replaces the whole list.
- List items are partial: `id`, `friendlyName`, `location`, `labels`, `externalDatasetReference`, `generatedID`.
- An access entry of an unknown kind decodes with every accessor `nil` and encodes without an entity. Callers remove it before an update.
- Tests: `DatasetClientTests.swift` (`BigQueryClientDatasetTests`), `DatasetTests.swift` (`DatasetTests`, `AclTests`).

### Notes

- `createDataset` and `updateDataset` take `selectedFields:`, and `updateDataset` takes `accessPolicyVersion:`. bigquery.md 4.7 lists neither. No `list*` method in this file takes `selectedFields:`, unlike the 4.7 rule.
- Property names are `maxTimeTravelHours`, `resourceTags`, `defaultEncryptionConfiguration` (4.7: `maxTimeTravel`, `tags`, `defaultEncryption`).

## Projects and service account

```swift
public struct Project: Sendable, Hashable { projectID: String; numericID: UInt64?; friendlyName: String? }
func getServiceAccount(projectID: String? = nil, options:) async throws -> String   // GET projects/{p}/serviceAccount
func listProjects(pageSize: Int? = nil, pageToken: String? = nil, options:) -> PagedSequence<Project>
```

- `getServiceAccount` returns the response `email`. It is retried, and a 404 throws.
- `listProjects` sends `GET /bigquery/v2/projects`, decoded by the hand-written `ProjectList` (not in the v2 protos). `projectID` comes from `projectReference.projectId`, falling back to `id`.
- Internal `ResourcePaging.query(pageSize, pageToken)` serves projects, routines, and models. 3D moves it to `BigQueryClient+Routines.swift`.
- Tests: `IAMTests.swift` (`listProjectsMapsEntries`, `listProjectsEmpty`, `getServiceAccountReturnsEmail`).

### Notes

- `listProjects` and `Project` are not in bigquery.md 4.7.

## Table IAM

```swift
public struct IAMPolicy: Sendable, Hashable { version: Int32?; bindings: [Binding]; etag: Data?
  struct Binding { role: String; members: [String]; condition: Expr? } }
public struct Expr: Sendable, Hashable { expression: String; title, description, location: String? }   // also on Acl
func getIAMPolicy(for table: TableID, requestedPolicyVersion: Int32? = nil, options:) async throws -> IAMPolicy
func setIAMPolicy(_ policy: IAMPolicy, for table: TableID, options:) async throws -> IAMPolicy
func testIAMPermissions(_ permissions: [String], for table: TableID, options:) async throws -> [String]
```

- Each call is `POST .../tables/{t}:getIamPolicy`, `:setIamPolicy`, or `:testIamPermissions` with a `google.iam.v1` body that omits `resource`.
- `getIAMPolicy` sends `options.requestedPolicyVersion` only when set. `setIAMPolicy` omits `policy.version` and `policy.etag` when `nil`, and is retried only when the policy has an `etag`. Get and test are always retried.
- On read, version `0`, an empty etag, and empty condition strings become `nil`. `testIAMPermissions` returns `[]` when none are granted.
- A 404 throws `.service`. These calls are not part of the `get*` -> `nil` rule.
- Tests: `IAMTests.swift` (`IAMPolicyTests`, `BigQueryClientIAMTests`, and `ResourceRouteTests`, which pins the method and path of every resource RPC, including the 3D routes).

## Tables

```swift
public struct Table: Sendable, Equatable {
  var id: TableID; friendlyName, description: String?; labels: [String: String]?; expirationTime: Date?
  schema: Schema?; timePartitioning; rangePartitioning; clustering; encryption; requirePartitionFilter: Bool?
  view: ViewDefinition?; materializedView: MaterializedViewDefinition?; externalDataConfiguration
  bigLakeConfiguration; tableConstraints: TableConstraints?; defaultCollation: String?
  defaultRoundingMode: GoogleCloudBigQuery.Field.RoundingMode?; maxStaleness: String?; resourceTags
  /* output */ snapshotDefinition, cloneDefinition, type: TableType?, etag, generatedID, selfLink, creationTime,
  lastModifiedTime, location, numRows: UInt64?, numBytes, num*Bytes, numPartitions, streamingBuffer
  init(id:, schema: = nil, friendlyName: = nil, description: = nil, labels: = nil)
  struct Field { friendlyName, description, expirationTime, labels, partitionExpiration, clustering,
                 defaultCollation, tableConstraints, primaryKey, resourceTags; label(_:), resourceTag(_:) }
}
public struct TableType: RawRepresentable { table, view, materializedView, external, snapshot, model }
public struct TableMetadataView: RawRepresentable { unspecified, basic, storageStats, full }
public struct ViewDefinition { query: String; userDefinedFunctions: [UserDefinedFunction]; useLegacySQL: Bool = false }
public struct MaterializedViewDefinition { query; enableRefresh: Bool?; refreshInterval: Duration?; allowNonIncrementalDefinition }
public struct SnapshotDefinition { baseTable: TableID; snapshotTime: Date }   // CloneDefinition: cloneTime
public struct TableConstraints { primaryKey: PrimaryKey? { columns }; foreignKeys: [ForeignKey] }
//   ForeignKey { name: String?; referencedTable: TableID; columnReferences: [ColumnReference] }

@discardableResult func createTable(_ table: Table, selectedFields: [String]? = nil, options:) async throws -> Table
func getTable(_ id: TableID, view: TableMetadataView? = nil, selectedFields: [String]? = nil, options:) async throws -> Table?
func listTables(in dataset: DatasetID, pageSize: Int? = nil, pageToken: String? = nil, options:) -> PagedSequence<Table>
func updateTable(_ table: Table, clearing: Set<Table.Field> = [], autodetectSchema: Bool = false,
                 ifMatch etag: String? = nil, selectedFields: [String]? = nil, options:) async throws -> Table
@discardableResult func deleteTable(_ id: TableID, options:) async throws -> Bool
```

- The table kind follows from which definition is set. Snapshot and clone definitions are read only.
- `getTable` always sends `view`, defaulting to `STORAGE_STATS` as Java does. `updateTable` sends `autodetect_schema=true` when asked.
- Create and update fill a `nil` project in the ID and in foreign key `referencedTable`s. Output-only fields, `managedTableType`, and `materializedView.lastRefreshTime` are never sent.
- `ViewDefinition.useLegacySQL` is always sent (default `false`). An absent wire value reads as `true`, the server default.
- `timePartitioning.expirationMs` is sent only when set. `.partitionExpiration` clears it ([bigquery.md](../bigquery.md) 7).
- List items are partial: `id`, `friendlyName`, `type`, `labels`, `creationTime`, `expirationTime`, partitioning, `clustering`, `requirePartitionFilter`, `generatedID`.
- A wire reference with an empty `datasetId` stays empty: `id.hasDataset == false`, `id.description == "p._anon"`. This is the dataset-less `TableID` contract from slice 1, cascaded in commit 91f8665600d1.
- Tests: `TableTests.swift`, `TableOperationsTests.swift`, `DatasetClientTests.swift` (`tableOfDatasetInAnotherProjectUsesThatProject`).

### Notes

- `createTable` and `updateTable` take `selectedFields:`. In `updateTable` it follows `ifMatch:`, while `updateDataset`, `updateRoutine`, and `updateModel` put it before.
- `Table` is `Equatable`, not `Hashable`. The property is `bigLakeConfiguration` (4.7: `biglakeConfiguration`). `defaultRoundingMode`, `maxStaleness`, the physical and logical byte counters, and `numPartitions` are not in 4.7.

## External data configuration

```swift
public struct ExternalDataConfiguration: Sendable, Hashable {
  init(sourceURIs: [String], format: DataFormat?, schema: Schema? = nil)   // format nil -> object table
  autodetect, ignoreUnknownValues: Bool?; compression, connectionID: String?; maxBadRecords: Int32?
  csvOptions; googleSheetsOptions { skipLeadingRows, range }; bigtableOptions; parquetOptions; avroOptions
  hivePartitioningOptions; decimalTargetTypes; fileSetSpecType; objectMetadata; referenceFileSchemaURI
  metadataCacheMode; timeZone, dateFormat, dateTimeFormat, timeFormat, timestampFormat: String?
}
public struct BigLakeConfiguration { connectionID, storageURI: String; fileFormat = .parquet; tableFormat = .iceberg }
// RawRepresentable: DecimalTargetType { numeric, bigNumeric, string }, FileSetSpecType { fileSystemMatch,
// newLineDelimitedManifest }, ObjectMetadata { simple, directory }, MetadataCacheMode { automatic, manual }
```

- When `externalDataConfiguration.schema` is set, `Table.wire` sends it as `table.schema` and drops it from the external configuration, as Java does. When it is `nil`, `table.schema` is kept (Java nulls it, an intentional difference in [bigquery.md](../bigquery.md) 7). Read an external table's schema from `Table.schema`.
- The same type serves query table definitions (slice 4B, [06-jobs.md](06-jobs.md)).
- `CSVOptions`, `ParquetOptions`, `AvroOptions`, and `HivePartitioningOptions` are core types with their wire conversions in this file. External tables use the nested `csvOptions` message. Load jobs reuse the others and flatten CSV.
- CSV `quote: ""` is sent and read back as `""`. An absent `fileSetSpecType` reads as `.fileSystemMatch` (a real proto3 zero). `objectMetadata` and `metadataCacheMode` read `UNSPECIFIED` as `nil`.
- `BigtableColumn.qualifier` is UTF-8 only, because the generated model has no `qualifierEncoded`.
- Tests: `ExternalDataConfigurationTests.swift`, `TableTests.swift` (`externalSchemaIsSentAsTableSchema`, `tableSchemaIsKeptWhenExternalConfigurationHasNone`), `TableOperationsTests.swift` (`*ExternalTableSendsSchemaAtTableLevel`).

## Table data

```swift
func listRows(in table: TableID, schema: Schema? = nil, selectedFields: [String]? = nil,
              startIndex: UInt64? = nil, pageSize: Int? = nil, pageToken: String? = nil,
              options:) async throws -> RowSequence                         // GET .../tables/{t}/data
func listPartitions(of table: TableID, options:) async throws -> [String]
```

- `schema == nil` -> one `tables.get` first with `fields=schema`, `view=BASIC`, and `selectedFields`, so the server projects the schema like the rows. No schema gives `Schema([])`.
- A given `schema` with `selectedFields` is projected locally: case-insensitive, nested paths such as `e.d.f` keep only the selected subfields, in schema order.
- The first page is fetched before returning, so `RowSequence.totalRows` is known at once. Later pages are lazy, keep `pageSize` and `selectedFields`, and drop `startIndex` because the token carries the position (Java resets it to 0).
- `formatOptions.timestampOutputFormat=ISO8601_STRING` is sent on every page unless the row schema has no `TIMESTAMP` column (`RowFormat.queryItems(for:)`).
- The hand-written `TableDataList` decodes the response. Rows and `RowSequence` are in [04-values.md](04-values.md). A missing table throws `.service` with `isNotFound`.
- `listPartitions` (in `BigQueryClient+Tables.swift`, added by 3C) reads `partition_id` from `{table}$__PARTITIONS_SUMMARY__` through `listRows`, or returns `[]` without that column.
- Tests: `TableDataTests.swift`, `TableOperationsTests.swift` (`listPartitionsReadsPartitionsSummary`).

### Notes

- bigquery.md 7 says the timestamp format is always requested. The code omits it when the known schema has no `TIMESTAMP`.
- The schema read also sends `view=BASIC` and `selectedFields`. bigquery.md 7 only says it selects `schema`.

## Streaming inserts

```swift
public struct InsertRow: Sendable, Equatable { var insertID: String?
  init<T: Encodable>(_ value: T, insertID: String? = nil) throws   // EncodingError unless value is an object
  init(_ values: [String: InsertValue], insertID: String? = nil) }
public struct InsertValue   // .string .int64 .float64 .bool .bytes .numeric .bigNumeric .timestamp(Date | BigQueryTimestamp)
                            // .date .time .dateTime .interval .range .array .record .null, plus literals
public struct InsertIDPolicy: RawRepresentable { generateMissing, none }
public struct InsertAllResponse: Sendable, Equatable { rowErrors: [Int: [BigQueryError.Detail]]; var hasErrors: Bool }
func insertAll(_ rows: [InsertRow], into table: TableID, skipInvalidRows: Bool = false,
               ignoreUnknownValues: Bool = false, templateSuffix: String? = nil,
               insertIDs: InsertIDPolicy = .generateMissing, options:) async throws -> InsertAllResponse
func insertAll<T: Encodable>(_ values: some Sequence<T>, into table: TableID, /* same */) async throws -> InsertAllResponse
```

- Wire: `POST .../tables/{t}/insertAll` with `{rows: [{insertId?, json}], skipInvalidRows, ignoreUnknownValues, templateSuffix?}`, sorted keys, both flags always sent.
- `.generateMissing` gives each row without an ID a lowercase UUID, once before the retry loop, so retries resend the same IDs. The request is retried only if every row has an `insertId`.
- `insertErrors[]` map to `rowErrors[index]` (missing index -> 0). Row failures are returned, never thrown. With neither flag set, one bad row stops the insert and the others carry a `stopped` error.
- The generic overload maps values through `InsertRow(_:)`, throws `EncodingError` before sending, and is what the mock seam forwards ([bigquery.md](../bigquery.md) 4.8).

### JSON encoding

`InsertRowEncoder` builds the JSON, because `JSONEncoder` encodes `Date`, `Data`, and large integers wrongly for BigQuery.

| Swift value | JSON |
| ----------- | ---- |
| `Date`, `BigQueryTimestamp` | an RFC 3339 UTC string (`Date` with microseconds, `BigQueryTimestamp` with up to 12 fractional digits) |
| `Data` | base64 |
| `Decimal`, `BigNumeric` | an exact decimal string |
| Integers | a number when the magnitude is at most 2^53, otherwise a decimal string |
| `Double`, `Float` | a number (`Float` in shortest form). `NaN` and infinities become `"NaN"`, `"Infinity"`, `"-Infinity"` |
| `Bool` | a boolean |
| `BigQueryDate`, `BigQueryTime`, `BigQueryDateTime`, `Interval` | the canonical string |
| `BigQueryRange` | an object with the bounds that are set, `{"start": "2024-01-01"}` |
| `URL` | its absolute string |
| Nested `Encodable`, dictionaries | an object (STRUCT) |
| Arrays | an array. A `nil` element becomes `null` |
| `nil` member | the key is omitted |

- Tests: `InsertAllTests.swift` (`InsertRowTests`, `InsertAllResponseTests`, `BigQueryClientInsertAllTests`).

### Notes

- The 4.7 table has no rows for `BigQueryRange`, `URL`, or `nil` array elements. insertAll rejects the `[start, end)` range string, so the code sends an object.

## Routines

```swift
public struct Routine: Sendable, Hashable {
  var id: RoutineID; type: RoutineType?; language: Language?; arguments: [Argument]?
  returnType: StandardSQLDataType?; returnTableType: StandardSQLTableType?; importedLibraries: [String]?
  body: String? /* definitionBody */; description: String?; determinismLevel: DeterminismLevel?
  remoteFunctionOptions: RemoteFunctionOptions? { endpoint, connection, userDefinedContext, maxBatchingRows }
  dataGovernanceType: DataGovernanceType? { dataMasking }; /* output */ etag: String?; creationTime, lastModifiedTime: Date?
  struct Argument { name: String?; kind: Kind? { fixedType, anyType }; mode: Mode? { in, out, inout }; dataType }
  // RoutineType { scalarFunction, procedure, tableValuedFunction, aggregateFunction }, Language { sql, javaScript, python, java, scala }
}
@discardableResult func createRoutine(_ routine: Routine, selectedFields: [String]? = nil, options:) async throws -> Routine
func getRoutine(_ id: RoutineID, selectedFields: [String]? = nil, options:) async throws -> Routine?
func listRoutines(in dataset: DatasetID, pageSize: Int? = nil, pageToken: String? = nil, options:) -> PagedSequence<Routine>
func updateRoutine(_ routine: Routine, selectedFields: [String]? = nil, ifMatch etag: String? = nil,
                   options:) async throws -> Routine                                         // PUT
@discardableResult func deleteRoutine(_ id: RoutineID, options:) async throws -> Bool
```

- `updateRoutine` is a full replacement (PUT), as in Java. `nil` properties are removed, and settings `Routine` does not model (`securityMode`, `strictMode`, Spark or Python options) are reset. Start from `getRoutine`. There is no `Routine.Field` or `clearing:`.
- The body omits output-only fields, `securityMode`, and each unset enum or string. `createRoutine` is not retried. List items are partial (no body or arguments).
- The `StandardSQL*` types are defined in slice 2A ([04-values.md](04-values.md)). Their wire conversions live in `Routine+Wire.swift`, mapping the `subType` oneof to `.array`, `.struct`, or `.range`.
- Tests: `RoutineTests.swift` (`RoutineTests`, `BigQueryClientRoutineTests`), `RoutineDataTypesTests.swift`, `IAMTests.swift` (`ResourceRouteTests`).

## Models

```swift
public struct Model: Sendable, Hashable {
  var id: ModelID; friendlyName, description: String?; labels: [String: String]?; expirationTime: Date?
  encryptionConfiguration: EncryptionConfiguration?
  /* output */ etag: String?; modelType: ModelType?; creationTime, lastModifiedTime: Date?; location: String?
  trainingRuns: [TrainingRun { startTime, trainingOptions }]; featureColumns, labelColumns: [StandardSQLField]
  struct Field { friendlyName, description, expirationTime, encryptionConfiguration, labels; label(_:) }
  // TrainingOptions { maxIterations, lossType, learnRate, learnRateStrategy, earlyStop, dataSplitColumn }
  // ModelType { linearRegression, logisticRegression, kMeans, matrixFactorization, tensorFlow, boostedTree*, arimaPlus }
}
func getModel(_ id: ModelID, selectedFields: [String]? = nil, options:) async throws -> Model?
func listModels(in dataset: DatasetID, pageSize: Int? = nil, pageToken: String? = nil, options:) -> PagedSequence<Model>
func updateModel(_ model: Model, clearing: Set<Model.Field> = [], selectedFields: [String]? = nil,
                 ifMatch etag: String? = nil, options:) async throws -> Model                // PATCH
@discardableResult func deleteModel(_ id: ModelID, options:) async throws -> Bool
```

- There is no `createModel`. Models come from `CREATE MODEL` queries.
- The PATCH body sets only `friendlyName`, `description`, `labels` (merged), `expirationTime`, and `encryptionConfiguration`, and omits each one left `nil`. Output-only fields and `defaultTrialId` are never sent.
- `TrainingOptions` reads `0` and `UNSPECIFIED` as `nil`. The output arrays are empty, never `nil`. List items are partial (no training runs or columns).
- Tests: `ModelTests.swift` (`ModelTests`, `BigQueryClientModelTests`), `IAMTests.swift` (`ResourceRouteTests`).
