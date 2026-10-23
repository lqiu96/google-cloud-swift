# Shared runtime hooks

Slice 0A. Three small changes in the shared runtime packages that the
BigQuery veneer needs and that other veneers can reuse. Files:
`pkgs/swift-google-gax/Sources/GoogleGax/HTTPClientHolder.swift`,
`pkgs/swift-google-gax/Sources/GoogleGax/HTTPClientResponse.swift`, and
`pkgs/swift-google-wkt/Sources/GoogleWKT/ProtoJSONDecoder.swift`.

These hooks are reviewed by the runtime owners. They add no public API outside
the `GoogleCloudInternal` SPI and change no existing behavior for callers that
do not opt in.

## Raw HTTP hooks

The veneer sends its own requests through `GoogleGax._HTTPClient` (see
[03-core.md](03-core.md#transport)) and reads whole response bodies with
`_HTTPClientResponse.data()`. BigQuery responses are much larger than the
gRPC-sized defaults: a `tabledata.list` or `getQueryResults` page can carry
tens of megabytes of row JSON.

Contract:

```swift
// GoogleGax, HTTPClientHolder
let inner = AsyncHTTPClient.HTTPClient(
  configuration: .init(decompression: .enabled(limit: .none)))

// GoogleGax, @_spi(GoogleCloudInternal) public struct _HTTPClientResponse
static let defaultMaximumResponseSize = 128 * 1024 * 1024   // was 32 MiB
public func data(upTo: Int) async throws -> Data              // no-copy transfer
public func data() async throws -> Data                       // upTo: defaultMaximumResponseSize
```

- Response decompression is enabled with no ratio limit, so a gzip-encoded
  body arrives decoded. The size cap still applies to the decoded body.
- The default maximum response size is 128 MiB. A larger body fails with an
  I/O error from `collect(upTo:)`, as before.
- `data(upTo:)` and the body read in the generic decode path build `Data` with
  `byteTransferStrategy: .noCopy`, so a large page is not copied a second time.

Consumers: `GaxHTTPTransport` in slice 1 and every row-reading path above it
(slices 3C, 4D, 5A).

## Decoder SPI

`_ProtoJSONDecoder` wraps every nested value in an `Interceptor<T>` so that
ProtoJSON rules (wrapper types, base64 bytes, enum names, defaults for missing
keys) apply. For row payloads this per-cell wrapping dominates decode time and
is not needed: row cells are plain JSON (`{"f":[{"v":...}]}`).

Contract:

```swift
// GoogleWKT
@_spi(GoogleCloudInternal) public protocol _RawJSONDecodable: Decodable {}
```

- A type that conforms to `_RawJSONDecodable` is decoded directly by the
  underlying `Foundation.JSONDecoder` container, at the top level and inside
  keyed and unkeyed containers, with no `Interceptor` wrapping. Its own
  `init(from:)` sees standard JSON rules.
- `String` values in keyed and unkeyed containers are decoded directly as well.
  A missing `String` key still decodes to `""` (the proto3 default), and
  `decodeIfPresent(String.self)` returns `nil` for a missing key.
- `decodeIfPresent` returns `nil` for a missing key or an explicit JSON `null`,
  and otherwise follows the same `String`, `Data` (base64), raw, and
  intercepted paths as `decode`.
- Types that do not conform behave exactly as before.

Consumers: the internal `WireRow` and `WireCell` row types
([04-values.md](04-values.md#row-and-fieldvalue)), which the table data path
(slice 3C) and the query path (slice 4D) decode. Slice 5A moves those row
paths to a streaming scanner
([08-performance.md](08-performance.md#streaming-row-scanner)), and the SPI
stays available for other callers.

### Notes

- Slice 0A has no tests of its own in the gax and wkt packages. The hooks are
  exercised by the BigQuery row and transport tests in slices 1, 2B, 3C, and
  5A, and `test_cmd` runs the full gax and wkt suites at every slice to show
  that existing behavior did not change.
