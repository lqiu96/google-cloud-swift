# Values, rows, and decoding

Slices 2A, 2B, and 2C, all under
`pkgs/swift-google-cloud-bigquery/Sources/GoogleCloudBigQuery/`. 2A:
`BigNumeric.swift`, `CivilTypes.swift`, `Interval.swift`,
`RoutineDataTypes.swift`. 2B: `Row.swift`, `FieldValue+Accessors.swift`,
`BigQueryRange.swift`, `RowSequence.swift`. 2C: `RowDecoder.swift`,
`RowSequence+Decode.swift`. Flat source: [../bigquery.md](../bigquery.md)
4.4, 4.5, 4.7 (slice 2 value types), and the section 7 cell rows. These slices
make no RPCs, so there is no retry or 404 behavior. Errors are `DecodingError`
(accessors, decoder) and `RequestError.malformedResponse` (wire rows).

## Scalar types

Slice 2A. Each type is `Sendable, Hashable, Codable, LosslessStringConvertible`
(civil types and `BigQueryTimestamp` are also `Comparable`). `Codable` is one
string in the canonical form, and `description` is that form. Query parameters
and insertAll encoding rely on it.

```swift
public struct BigNumeric {
  public let description: String          // the source text, verbatim
  public init?(_ description: String)     // [+-]digits[.digits][(e|E)[+-]digits]
  public init(_ value: some BinaryInteger); public init(_ value: Decimal)   // precondition: not NaN
  public var decimalValue: Decimal { get } // rounded to 38 significant digits
}
public struct BigQueryDate { year, month, day: Int; init(year:month:day:)   // not validated
  init?(_:)                                // YYYY-[M]M-[D]D, validated
  init(_ date: Date, in timeZone: TimeZone = UTC) }
public struct BigQueryTime { hour, minute, second, nanosecond: Int; init?(_:) }  // [H]H:[M]M:[S]S[.F<=9]
public struct BigQueryDateTime { date: BigQueryDate; time: BigQueryTime; init?(_:) }  // space or T
public struct BigQueryTimestamp {
  public let seconds: Int64                // floor before 1970
  public let picoseconds: Int64            // 0..<1_000_000_000_000
  public init(seconds: Int64, picoseconds: Int64 = 0)   // normalizes
  public init(micros: Int64); public init(_ date: Date)  // Date -> nearest microsecond
  public init?(_ description: String)      // ISO 8601 / RFC 3339, T or space, <= 12 digits, UTC default
  public var micros: Int64 { get }         // floor
  public var date: Date { get }
}
public struct Interval {
  public var months: Int; public var days: Int; public var time: Duration
  public init(months: Int, days: Int, time: Duration)
  public init(years: Int = 0, months: Int = 0, days: Int = 0, hours: Int64 = 0,
              minutes: Int64 = 0, seconds: Int64 = 0, nanoseconds: Int64 = 0)
  public init?(_ description: String)      // [-]Y-M [-]D [-]H:M:S[.F] or ISO 8601 P...T...
}
```

- `BigNumeric` keeps exact text (S§3 #14). Equality and hashing use a
  normalized number, so `BigNumeric("1.50") == BigNumeric("1.5")`. The service
  checks the range.
- Output: date `YYYY-MM-DD`. Time `HH:MM:SS` plus 6 fractional digits when
  non-zero (9 below a microsecond). DateTime `YYYY-MM-DD HH:MM:SS[.FFFFFF]`.
  Timestamp `YYYY-MM-DDTHH:MM:SS.ffffff[ffffff]Z` in UTC (12 digits only when
  the sub-microsecond part is non-zero).
- `Interval` parts are independent. `description` normalizes year-month, so
  `Interval(months: 14)` prints `1-2 0 0:0:0`. Decoding accepts both forms.
- A malformed string throws `DecodingError.dataCorrupted` when decoding.

Internal helpers used by 2B and later slices:

```swift
struct DecimalText: Hashable { init?(_:); var plainText: String; func roundedInteger(shiftedBy:) -> Int64? }
enum Timestamp { static func micros(from: Date) -> Int64; static func date(fromMicros:) -> Date
  static func format(micros:separator:suffix:) -> String
  static func parseCell(_:) -> BigQueryTimestamp?       // ISO 8601, int micros, float seconds
  static func isValidParameterText(_:) -> Bool }        // timestamp query-parameter literal
```

Tests: `Tests/FieldValueTests.swift` suites `IntervalTests` (U.FieldValue.04,
U.QueryParameterValue.05), `BigNumericTests`, `CivilTypesTests`.

### Notes

- `BigQueryTimestamp` is in `CivilTypes.swift`. The flat slice table (section
  10) lists a separate `BigQueryTimestamp.swift`.

## Routine data types

Slice 2A. GoogleSQL types for routine arguments and return types and model
columns. `Sendable, Hashable`, with no wire mapping yet.

```swift
public struct StandardSQLDataType {
  public struct TypeKind: RawRepresentable, CustomStringConvertible {   // extensible
    int64, bool, float64, string, bytes, timestamp, date, time, dateTime, interval,
    geography, numeric, bigNumeric, json, array, `struct`, range }
  public let typeKind: TypeKind
  public init(_ typeKind: TypeKind)
  public static func array(of:) / `struct`(_ fields: [StandardSQLField]) / range(of:) -> Self
  public var arrayElementType: Self?; structType: StandardSQLStructType?; rangeElementType: Self?
}
public struct StandardSQLField { var name: String?; var type: StandardSQLDataType?; init(_:type:) }
public struct StandardSQLStructType { var fields: [StandardSQLField] }
public struct StandardSQLTableType { var columns: [StandardSQLField] }
```

- The sub-type is an internal `indirect enum`. Each sub-type accessor is `nil`
  unless the kind matches.
- `StandardSQLField.type` is `nil` when the service omits it (templated
  routine argument). `name` is `nil` for an unnamed struct field.

### Notes

- The flat doc does not list `RoutineDataTypes.swift` in slice 2. Wire
  conversion is expected with routines and models in
  [05-resources.md](05-resources.md). 2A to 2C have no tests for these types.

## Row and FieldValue

Slice 2B, `Row.swift`. `FieldValue` is closed: the four wire cell shapes.

```swift
public struct Row: Sendable, Equatable {
  public let schema: Schema                  // for a STRUCT, the struct's fields
  public let values: [FieldValue]            // schema order
  public init(schema: Schema, values: [FieldValue])
  public subscript(index: Int) -> FieldValue       // precondition: in range
  public subscript(name: String) -> FieldValue?    // exact, then case-insensitive (U.FieldList.01)
}
public enum FieldValue: Sendable, Equatable { case null, scalar(String), array([FieldValue]), record(Row) }
// internal, used by table data and query slices:
struct WireRow: _RawJSONDecodable { var f: [WireCell] }   // {"f": [{"v": ...}]}
extension Row { static func rows(from: [WireRow], schema: Schema) throws -> [Row]
                init(wire: WireRow, schema:) throws; init(wire: WKTStruct, schema:) throws }
```

| Cell | Result |
| ---- | ------ |
| A REPEATED field | `.array`. Each element is parsed with the field's schema in NULLABLE mode. A `null` array becomes `[]` (S§3 #16). |
| A STRUCT field | `{"f":[...]}` becomes `.record(Row)` with the subfield schema (cached in `Schema.childSchemas`). |
| Anything else | A string becomes `.scalar`, and `null` becomes `.null`. |

- This fixes Java's REPEATED cells parsed with a null schema (B§6), so
  `ARRAY<STRUCT>` elements support `row[name]`. Intentional difference.
- The cell count must equal `schema.fields.count`. With `selectedFields`, pass
  the projected schema.
- `RequestError.malformedResponse("malformed BigQuery row: ...")` for: no `f`
  array, wrong cell count, non-array for REPEATED, array for non-REPEATED,
  object for non-STRUCT.

Tests: `Tests/RowTests.swift` suite `RowTests` (U.FieldValueList.01 to .03,
U.FieldList.01 to .03).

### Notes

- Flat 4.5 puts `Row`, `FieldValue`, and `FieldValue(wire:field:)` in core. The
  code adds them in 2B. Core has only `Schema`, `PagedSequence`, `RowFormat`.
- `WireCell` also accepts a JSON bool or number as `.scalar` text. The flat doc
  names strings only.

## Typed accessors

Slice 2B, `FieldValue+Accessors.swift`. Accessors read the cell text and do not
check the column type.

```swift
extension FieldValue {
  public var isNull: Bool
  // shape accessors, never throw: nil for NULL or another shape
  public var stringValue, jsonValue, geographyValue: String?; arrayValue: [FieldValue]?; recordValue: Row?
  // parsing accessors, { get throws }: nil for NULL
  int64Value: Int64?, doubleValue: Double? (NaN, +-Infinity), boolValue: Bool? (any case),
  bytesValue: Data? (base64), numericValue: Decimal?, bigNumericValue: BigNumeric? (also NUMERIC),
  timestampMicros: Int64?, timestampValue: Date?, preciseTimestampValue: BigQueryTimestamp?,
  dateValue: BigQueryDate?, timeValue: BigQueryTime?, dateTimeValue: BigQueryDateTime?,
  intervalValue: Interval? (both forms), rangeValue: BigQueryRange? (elementType nil)
}
```

- Array or struct -> `DecodingError.typeMismatch`. Unparsable text ->
  `DecodingError.dataCorrupted`.
- NULL returns `nil`. Java throws (B§6). Intentional difference.
- Timestamps: the client requests
  `formatOptions.timestampOutputFormat=ISO8601_STRING` (core `RowFormat`).
  `Timestamp.parseCell` accepts ISO 8601 (up to 12 fractional digits), integer
  micros, and float seconds rounded half away from zero. `timestampMicros`
  floors picoseconds, and `timestampValue` is built from it.
- Internal `checkedText(as:)` and `checkedRecord()` are shared with the
  [row decoder](#row-decoder).

Tests: `Tests/FieldValueTests.swift` suite `FieldValueTests` (U.FieldValue.01
to .03, U.QueryParameterValue.03 and .09).

## Range values

Slice 2B, `BigQueryRange.swift`. A half-open `[start, end)` of `DATE`,
`DATETIME`, or `TIMESTAMP`. Bounds stay in string form.

```swift
public struct BigQueryRange: Sendable, Hashable, Codable, CustomStringConvertible {
  public var start, end: String?              // nil = unbounded
  public var elementType: FieldType?          // .date, .dateTime, .timestamp
  public init(start: String?, end: String?, elementType: FieldType? = nil)
  public init?(_ text: String, elementType: FieldType? = nil)   // "[a, b)", UNBOUNDED/NULL any case
  public static func date(from:to:) / dateTime(from:to:) / timestamp(from: Date?, to: Date?)
  @_disfavoredOverload public static func timestamp(from: BigQueryTimestamp?, to: BigQueryTimestamp?)
  public var startValue, endValue: FieldValue  // .null if unbounded, else .scalar
}
```

- `description` and `Codable` use `[start, end)` with `UNBOUNDED`. Decoding
  leaves `elementType` `nil`. Factories set it, and write timestamp bounds as
  `YYYY-MM-DD HH:MM:SS.ffffff[ffffff]+00:00`.
- A cell has no type, so `rangeValue` leaves `elementType` `nil`. `Row.decode`
  (2C) fills it from `Field.rangeElementType`. Query parameters
  ([06-jobs.md](06-jobs.md)) need it.

Tests: `Tests/FieldValueTests.swift` suite `BigQueryRangeTests` (U.Range.01,
U.Range.02).

## Row sequence

Slice 2B, `RowSequence.swift`. The lazy row stream of table data and query
results, over core `PagedSequence` (empty pages skipped, empty token ends).

```swift
public struct RowSequence: AsyncSequence, Sendable {   // Element == Row
  public let schema: Schema              // empty when the result has no schema
  public let totalRows: UInt64?          // nil when not reported. nil does not mean empty.
  public init(schema: Schema, totalRows: UInt64?, rows: PagedSequence<Row>)
  public init(schema: Schema, rows: [Row])               // test doubles, totalRows = rows.count
  public var pages: PagedSequence<Row>.Pages { get }
  public func collect() async throws -> [Row]
}
```

- The producing slice owns the fetch closure, its retries, and its context
  (job, page size, selected fields on every page), which fixes Java's lost
  `jobId` (B§4). See [05-resources.md](05-resources.md) and
  [07-query.md](07-query.md).

Tests: `Tests/PagedSequenceTests.swift` `fixedItemsForTestDoubles`.

## Row decoder

Slice 2C, `RowDecoder.swift` and `RowSequence+Decode.swift`.

```swift
extension Row { public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T }
extension RowSequence {
  public func decode<T: Decodable>(_ type: T.Type = T.self) -> some AsyncSequence<T, any Error> & Sendable
}
extension FieldValue: Decodable {}   // inside Row.decode only: the unconverted cell
extension Row: Decodable {}          // inside Row.decode only: a STRUCT cell, unconverted
```

| Swift type | Column type |
| ---------- | ----------- |
| `String` | any scalar, as text |
| `Bool`, integers, `Double`, `Float` | `BOOL`, `INT64`, `FLOAT64` |
| `Decimal`, `BigNumeric` | `NUMERIC`, `BIGNUMERIC` |
| `Date`, `BigQueryTimestamp` | `TIMESTAMP`, `TIMESTAMP(12)` |
| `Data` | `BYTES` |
| `BigQueryDate`, `BigQueryTime`, `BigQueryDateTime` | `DATE`, `TIME`, `DATETIME` |
| `Interval`, `BigQueryRange` | `INTERVAL`, `RANGE` (element type from the schema) |
| arrays, nested `Decodable` or `Row` | `REPEATED`, `STRUCT` |
| `FieldValue` | any column, unconverted |

- Keys match columns like `Row[name]`. Cells convert as their typed accessor
  does. `Date`, `BigQueryTimestamp`, `Data`, `Decimal`, and `BigQueryRange` are
  intercepted, other scalars decode through their string `Codable` form.
- Missing column -> `keyNotFound`. NULL for non-optional -> `valueNotFound`.
  Wrong shape -> `typeMismatch`. Bad text -> `dataCorrupted`. Errors carry the
  full coding path, for example `["visits", "Index 0", "day"]`.
- Optional properties decode NULL or a missing column as `nil`.
- `FieldValue` and `Row` throw `typeMismatch` from any other decoder.
- `RowSequence.decode` is a dedicated `Sendable` sequence (no closure captures
  the metatype). It decodes lazily and throws the first `DecodingError`.

Tests: `Tests/RowDecoderTests.swift` suite `RowDecoderTests`
(U.FieldValueList.01 to .03).

### Notes

- Flat 4.4 gives `some AsyncSequence<T, any Error>`. The code adds `& Sendable`
  and a `T.self` default.
- The 2B `BigQueryRange.elementType` doc comment cites `Row.decode`, which
  lands in 2C.
