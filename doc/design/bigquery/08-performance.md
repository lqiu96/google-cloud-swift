# Performance: streaming rows and page prefetch

Slice 5A (`perf(bigquery): stream row JSON and prefetch`, head 8ac899db533b on
4E) replaces the decode path of every row read and overlaps page fetches with
row consumption. It covers `Row.swift` (`RowJSONScanner`),
`BigQueryClient+TableData.swift` (`listRows`, `HTTPPagePrefetcher`),
`BigQueryClient+Query.swift` (`QueryPage`, `rowSequence`), `PagedSequence.swift`
(an internal first-page hook), and `Tests/RowTests.swift`. The public API does
not change. The commit message has a subject only, and
[../bigquery.md](../bigquery.md) has no section for this slice, so this spec is
derived from the code.

## Streaming row scanner

### Baseline row path (2B, 3C, 4D)

Before 5A, every row was materialized three times: the ProtoJSON decoder's
parse, a `[WireRow]` / `[WireCell]` tree, then `[Row]`.

- 2B ([04-values.md](04-values.md#row-and-fieldvalue)): `WireRow` and `WireCell`
  are `_RawJSONDecodable`. `Row.rows(from: [WireRow], schema:)` ->
  `Row(wire:schema:)` -> `FieldValue(wire:field:childSchema:)` builds the cells.
- 3C ([05-resources.md](05-resources.md#table-data)): `listRows` decoded
  `TableDataList { totalRows: String?, pageToken: String?, rows: [WireRow]? }`
  with `transport.json`, then `page(schema:)`.
- 4D ([07-query.md](07-query.md#query-execution)): `WireQueryResponse.rows` and
  `WireGetQueryResultsResponse.rows` were `[WireRow]?`. `QueryPage.rows` kept
  them as `[WireRow]` until `rowSequence` converted them.

### What 5A changes

| Read | Before 5A | After 5A |
|---|---|---|
| `tabledata.list`, every page | `transport.json` -> `TableDataList` -> `Row.rows` | `transport.send` -> `RowJSONScanner.decodePage` on the raw bytes |
| `jobs.query` | `transport.json(validate:)` -> `WireQueryResponse.rows` | `transport.run` + `attempt` + `BigQueryTransport.decode` for metadata, raw body kept, `RowJSONScanner.decodeRows` |
| `getQueryResults` (first page, wait loop) | `transport.json` -> `WireGetQueryResultsResponse.rows` | `transport.send`, metadata via `BigQueryTransport.decode`, rows via `decodeRows` |
| `getQueryResults` later pages | `queryResultsPage` + `Row.rows` | prefetcher request + `decodePage` |

- `TableDataList` is deleted. `rows` is removed from both query wire models.
- `QueryPage.rows` is `[Row]`. `QueryPage.init(_:body:fallbackSchema:)` decodes
  them only when a schema is known (`response.schema ?? fallbackSchema`).
- `queryResultsPage` now returns `(WireGetQueryResultsResponse, Data)`, and
  `sendQueryResultsRequest` returns the raw `HTTPResponse`.
- The `jobs.query` attempt still decodes inside the retry loop, so the
  `jobRateLimited` retry with a fresh `requestId` (W3) is unchanged.

### Contract

```swift
struct RowJSONScanner {                       // internal, Row.swift
  static func decodePage(from data: Data, schema: Schema) throws
    -> (totalRows: UInt64?, page: Page<Row>)  // tabledata.list, getQueryResults
  static func decodePage(from bytes: [UInt8], schema: Schema) throws
    -> (totalRows: UInt64?, page: Page<Row>)
  static func decodeRows(from data: Data, schema: Schema) throws -> [Row]  // "rows" only
  static func decodeRow(from data: Data, schema: Schema) throws -> Row     // one {"f": [...]}
  static func peekPageToken(from bytes: [UInt8]) -> String?                // nil on any failure
}
```

The scanner walks the UTF-8 bytes once and builds `Row` and `FieldValue`
directly. An empty body decodes as an empty page (or `[]`).

### Invariants kept from the baseline

- A row has exactly one cell per schema field. Otherwise it throws
  `row has N cells but the schema has M`. A missing or `null` `"f"` counts as
  0 cells.
- Scalars stay strings. JSON `true` / `false` -> `"true"` / `"false"`. A JSON
  number -> `String(Double(token))`, so `36` -> `"36.0"`, as `WireCell` did.
- REPEATED: a `null` or missing `v` -> `.array([])`. Elements are `{"v": ...}`
  objects, decoded with mode `.nullable` and
  `childSchema ?? Schema(field.fields)`.
- STRUCT: an object `v` is accepted only for `type == .struct` and becomes
  `.record(Row)` with `schema.childSchemas[i] ?? Schema(field.fields)`.
- An array `v` on a non-repeated field throws. A missing `v` or a `{}` cell is
  `.null` (`.array([])` when repeated).
- Unknown keys in the envelope, row, and cell objects are skipped.
- An absent, `null`, or empty `pageToken` -> `nextPageToken == nil`.
  `totalRows` is `nil` when absent or `null` (W6).
- Rows use the projected schema (`selectedFields`), as before.
- Requests are unchanged: same paths and query items, W2 format options,
  `startIndex` only on the first `tabledata.list` page.
- A malformed first page still throws from `listRows` or `query`.

### Behavior differences

- Every scanner failure is `RequestError.malformedResponse("malformed BigQuery
  row: ...")`, including envelope syntax errors. The baseline wrapped decoder
  failures as `malformedResponse("cannot decode <Type>: ...")`.
- `tabledata.list` `totalRows` is accepted as a JSON string or number. The
  baseline accepted a string only.
- Strings without escapes are sliced from the buffer. Simple escapes are
  decoded in place. A string with a `\u` escape is re-decoded with Foundation
  `JSONDecoder`, so surrogate pairs are correct.
- The scanner is not a validating JSON parser. `skipValue` counts brackets and
  skips strings. `decodeRows` returns at the `"rows"` key and does not read the
  rest of the object.
- `jobs.query` and `getQueryResults` bodies go through the ProtoJSON metadata
  decoder and then through the scanner. Only `tabledata.list` pages skip the
  ProtoJSON decoder.
- Rows of a page without a schema (DDL) are no longer decoded at all. The
  result is the same empty `RowSequence`.

### Notes

- `WireRow`, `WireCell`, `Row.rows(from:schema:)`, `Row(wire: WireRow, ...)`
  and `FieldValue(wire: WireCell.Value, ...)` have no production caller after
  5A. They stay in `Row.swift`. The `WKTStruct` overloads are still used by the
  `RowTests` and `RowDecoderTests` helpers.
- 5A also reorders `WireCell.init(from:)` to test `null` before `String`.

### Tests

- `RowTests.scannerDecodesPageAndEscapedValues`: envelope with `kind`, string
  `totalRows`, `pageToken`, escapes including `\uD83D\uDE00`, number ->
  `"36.0"`, boolean, repeated with a `null` element, struct, repeated struct,
  `null` repeated -> `[]`, and `peekPageToken`.
- `RowTests.scannerRejectsMalformedRows`: `"f"` not an array, too few cells,
  too many cells, array on a non-repeated field, non-array on a repeated field.
- Unchanged tests pin the wire and the 404 contract: `TableDataTests`
  (`listRowsReadsSchemaThenRows`, `nextPageUsesTokenWithoutStartIndex`,
  `listRowsRequestsISO8601TimestampsWhenSchemaHasTimestamp`,
  `listRowsOfMissingTableThrows`) and `QueryClientTests`
  (`fastPathReadsLaterPagesFromGetQueryResults`,
  `completeFastPathWithoutSchemaReadsGetQueryResultsOnce`,
  `slowPathPollsWithZeroMaxResultsAndReadsDestinationTable`,
  `statelessResultWithMorePagesIsMalformed`, `resultWithoutSchemaHasNoRows`).

## Page prefetch

### Contract

```swift
final class HTTPPagePrefetcher: Sendable {    // internal, BigQueryClient+TableData.swift
  init(sendRequest: @escaping @Sendable (_ pageToken: String) async throws -> HTTPResponse)
  func prefetch(_ token: String)
  func fetchPage(_ token: String, schema: Schema) async throws -> Page<Row>
}

extension PagedSequence {                     // internal; public inits unchanged
  init(firstPage: Page<Element>, onFirstPageToken: (@Sendable (String) -> Void)?,
       fetch: @escaping Fetch)
}
```

`listRows` and the query `rowSequence` each create one prefetcher per
`RowSequence` and capture it in the `fetch` closure.

### Behavior

- State is one `(token, Task<[UInt8], any Error>)` slot behind a `Mutex`. At
  most one page request is in flight per prefetcher.
- `prefetch(token)` ignores an empty token and is a no-op when the same token
  is already in flight. Otherwise it cancels the previous task and starts
  `Task { Array(try await sendRequest(token).body) }`.
- `fetchPage(token)` takes the task when the slot holds `token` (and clears
  the slot), then awaits its bytes. Otherwise it sends the request directly.
  It then calls `peekPageToken` on the bytes and `prefetch(next)` before it
  decodes the current page. So the request for page N+1 overlaps the decode and
  consumption of page N.
- The first page: `PagedSequence.Pages.AsyncIterator` calls `onFirstPageToken`
  when it yields the already-fetched first page with a non-empty token.
  Prefetching starts when iteration starts, never when `listRows` or `query`
  returns.
- `deinit` cancels the task still held in the slot.

### Wire behavior

- `sendRequest` builds the same request as the baseline `fetch`, and sends it
  with `transport.send` (retry loop, error mapping, per-call `options`).
- `listRows`: `GET .../tables/{t}/data` with format options, `maxResults`,
  `pageToken`, `selectedFields`, and no `startIndex`.
- Query results: `tabledata.list` on the destination table when it is known
  (slow path), else `GET .../queries/{job}` with location, format options,
  `pageToken`, `maxResults`.
- Query prefetch runs only when `jobID != nil`. `rowSequence` passes a `nil`
  job when the first page has no token, and a token without a job still throws
  `malformedResponse`.

### Errors, 404, and cancellation

- A failed prefetch stores its error in the task. It is thrown from
  `fetchPage` when the consumer reaches that page, never earlier.
- A 404 on a later page is a thrown `BigQueryError` (`.service`, 404), as in
  the baseline. Row reads have no `nil` mapping
  ([03-core.md](03-core.md#not-found-contract)).
- If the consumer stops after page N, page N+1 may already have been
  requested. That is the only extra traffic.
- The prefetch runs in an unstructured `Task`. Cancelling the consuming task
  does not cancel it, and a consumer that took the task waits for it to finish.
  The task is cancelled only when a different token replaces it or the
  prefetcher is deallocated. Q3 still holds: nothing sends `jobs.cancel`.
- Several iterators of one `RowSequence` share the slot. A token mismatch falls
  back to a direct request, so results stay correct and only the prefetch is
  wasted.

### Notes

- [../bigquery.md](../bigquery.md) section 8 says each iterator owns its paging
  state. The page token state is still per iterator, but the prefetch slot is
  shared by every iterator of one `RowSequence`.
- [../bigquery.md](../bigquery.md) section 4.4 lists only the public
  `PagedSequence` inits. The `onFirstPageToken` init is internal.

### Tests

- No unit test targets `HTTPPagePrefetcher` directly. Paging through it is
  pinned by `TableDataTests.nextPageUsesTokenWithoutStartIndex`,
  `QueryClientTests.fastPathReadsLaterPagesFromGetQueryResults`, and
  `QueryClientTests.slowPathPollsWithZeroMaxResultsAndReadsDestinationTable`.
- Live (5B, [09-protocol.md](09-protocol.md#integration-tests)):
  `QueryIntegrationTests.multiPageResultsAreFetchedLazily` (IT-103, 25 rows in
  pages of 10) and `TableIntegrationTests.listRowsOfPublicTableWithStartIndex`.
