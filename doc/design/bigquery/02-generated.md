# Generated wire module and release wiring

Slice 0B. Adds the generated `GoogleCloudBigQueryV2` package, the librarian
configuration that produces it, the veneer's generated `PackageVersion`, and
the flat design documents that these specs come from. Files:
`generated/swift-google-cloud-bigquery-v2/**` (282 files),
`generated/_libraries.json`, `librarian.yaml`,
`pkgs/swift-google-cloud-bigquery/Sources/GoogleCloudBigQuery/generated/PackageVersion.swift`,
and `doc/design/bigquery*.md`.

Everything in this slice is generated or research. Review it for configuration,
not for line-by-line content.

## Generated wire module

`librarian generate google-cloud-bigquery-v2` produces
`generated/swift-google-cloud-bigquery-v2`, product and module
`GoogleCloudBigQueryV2`, from `google/cloud/bigquery/v2`.

- `Package.swift` depends on `swift-google-auth`, `swift-google-gax`,
  `swift-google-type`, `swift-google-wkt` (all through
  `localOrRemotePackage`), and `swift-log`. Settings:
  `InternalImportsByDefault`, `NonisolatedNonsendingByDefault`, and strict
  memory safety. `GOOGLE_CLOUD_SWIFT_LOCAL_DEPS=true` resolves the
  dependencies as `../..` local paths.
- Sources hold one file per proto message (`Dataset`, `Table`, `Job`,
  `JobStatistics2`, `QueryRequest`, `QueryResponse`, `TableFieldSchema`, and so
  on) plus seven services (`DatasetService`, `JobService`, `ModelService`,
  `ProjectService`, `RoutineService`, `RowAccessPolicyService`,
  `TableService`), each with `+Logging`, `+Retry`, `+Stub`, and `+Transport`
  files. `Snippets/` holds one sample per RPC.
- The module builds with `-warnings-as-errors`.

The veneer imports it with a plain internal `import GoogleCloudBigQueryV2`.
No generated type appears in the veneer's public API (see
[03-core.md](03-core.md#wire-conversions)).

## Why only the messages

The veneer uses the generated message types as wire models and does not use
the generated services. The reasons, from the D2 spike recorded in
[../bigquery.md](../bigquery.md) section 2.1:

1. The generated `ServiceError` drops BigQuery's
   `error.errors[{reason, location, message, debugInfo}]`. Retry
   classification and `BigQueryError` need the reason.
2. A `DELETE` returns `204` with an empty body and
   `content-type: application/json`. The generated client then throws a JSON
   decode error even though the delete succeeded.
3. The generated stubs and transport are internal to the generated module, so
   they cannot be wrapped or tested through a fake. The protos also lack
   `tabledata.list`, `insertAll`, the table IAM mixin, `projects.list`, and
   the upload endpoint, so a hand-written transport is needed anyway.

What the messages do handle, verified live in the spike:

- Wrapper types (`Int64Value`, `BoolValue`, ...) map to Swift optionals.
- `tabledata.list` and `jobs.query` rows decode as `[GoogleWKT.WKTStruct]`,
  which keeps the `{"f":[{"v":...}]}` shape.
- `QueryParameterValue` round-trips, including `arrayValues`,
  `structValues`, and `rangeValue`.
- Stateless queries return `jobReference == nil` plus a `queryId`.
- Schemas come back with legacy type names (`INTEGER`, `RECORD`) even when the
  request used `INT64`.
- `_ProtoJSONEncoder` omits `nil` optionals and empty collections but emits
  proto3 scalar defaults (`""`, `"0"`, `*_UNSPECIFIED`) for non-wrapper
  fields. [03-core.md](03-core.md#request-bodies) covers how PATCH handles
  them.

## Librarian configuration

Two entries are added to `librarian.yaml`:

```yaml
- name: google-cloud-bigquery
  version: 0.3.0
  output: pkgs/swift-google-cloud-bigquery/Sources/GoogleCloudBigQuery/generated
  swift:
    library_name_override: GoogleCloudBigQuery
    modules:
      - output: pkgs/swift-google-cloud-bigquery/Sources/GoogleCloudBigQuery/generated
        api_path: ""
        module_type: package-version
- name: google-cloud-bigquery-v2
  version: 0.3.0
  swift:
    library_name_override: GoogleCloudBigQueryV2
    skipped_ids:
      - .google.cloud.bigquery.v2.BigtableColumn.qualifier_encoded
```

- The `qualifier_encoded` skip works around a generator bug: a
  `google.protobuf.BytesValue` field does not trigger the `public import
  Foundation` it needs. As a result the veneer cannot set `qualifierEncoded`,
  and the Bigtable external option exposes only `qualifierString`.
- `librarian tidy` strips comments from `librarian.yaml`, so this rationale
  lives here and in [../bigquery.md](../bigquery.md) section 13.
- `generated/_libraries.json` gains the `swift-google-cloud-bigquery-v2`
  entry (docs URL, API short name `bigquery`, product "BigQuery API").

## Package version

`PackageVersion.swift` is generated into the veneer by the
`google-cloud-bigquery` entry:

```swift
enum PackageVersion { static let version: Swift.String = "0.3.0" }
```

- The version starts at 0.3.0 to match `google-cloud-bigquery-v2`.
- `BigQueryTransport` uses it to send
  `x-goog-api-client: gl-swift/... gccl/<version>` on every request
  ([03-core.md](03-core.md#transport)).
- The veneer's `Package.swift` joins the create-release skill's list of
  hand-written manifests in slice 5B
  ([09-protocol.md](09-protocol.md#release-tooling)).

## Flat design documents

Slice 0B also adds the research and design set the port was built from. These
files stay in place. The modular specs in this directory supersede
`bigquery.md` where they differ.

| File | Content |
|---|---|
| `doc/design/bigquery.md` | single-file design: decisions, API sketch, transport, query path, Java mapping, slices, parity |
| `doc/design/bigquery_reference_behavior.md` | Java client behavioral contract |
| `doc/design/bigquery_cross_language.md` | Go, Python, Node, Rust survey and recommended Swift scope |
| `doc/design/bigquery_test_baseline.md` | Java unit and IT baseline with stable IDs and PORT, ADAPT, N/A, DEFERRED status |

### Notes

- Before the first release the `swift-google-cloud-bigquery-v2` repository
  must be published. Until then the veneer resolves only with
  `GOOGLE_CLOUD_SWIFT_LOCAL_DEPS=true`.
- `test_cmd` builds `generated/swift-google-cloud-bigquery-v2` at this slice
  because the veneer package does not exist yet.
