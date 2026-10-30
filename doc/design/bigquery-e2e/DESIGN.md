# BigQuery Values, Rows, and Decoding

## Intent

Provide lossless Swift value types (`BigNumeric`, civil date/time types, `BigQueryTimestamp`, and `Interval`), zero-copy row cell accessors (`Row`, `FieldValue`, `BigQueryRange`, and `RowSequence`), and `Decodable` row decoding (`RowDecoder`) for the Google Cloud BigQuery Swift client.

## Scalar Types

Slice A (`BigNumeric.swift`, `CivilTypes.swift`, `Interval.swift`, `RoutineDataTypes.swift`).

### Contract: Lossless Scalar Value Representations

Each scalar type conforms to `Sendable`, `Hashable`, `Codable`, and `LosslessStringConvertible`, preserving exact wire text representations for `BIGNUMERIC`, `DATE`, `TIME`, `DATETIME`, `TIMESTAMP`, and `INTERVAL`.

## Row and FieldValue

Slice B (`Row.swift`, `FieldValue+Accessors.swift`, `BigQueryRange.swift`, `RowSequence.swift`).

### Contract: Typed Cell Accessors and Range Parsing

`Row` provides O(1) column name and index lookup over `FieldValue` cells, `FieldValue` converts wire strings into typed Swift scalars, `BigQueryRange` parses `[start, end)` bounds with `UNBOUNDED` sentinel support, and `RowSequence` streams paginated rows.

## Row Decoder

Slice C (`RowDecoder.swift`, `RowSequence+Decode.swift`).

### Contract: Schema-Aware Decodable Row Mapping

`Row.decode(_:)` and `RowSequence.decode(_:)` decode BigQuery rows into Swift `Decodable` structs using schema column names and types while reporting full coding paths on decoding errors.
