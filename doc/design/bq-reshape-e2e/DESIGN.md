# BigQuery Reshape E2E Design

## Intent
Verify splitting, rearranging, and removing slices in a stack without merging any PRs.

## Core Types
Defines `BigQueryType` and `BigQueryValue`.

## Range Type
Defines `BigQueryRange<Bound>` for bounded interval values.

## Row Model
Defines `FieldValue` and `Row` keyed lookup over `BigQueryValue`.

## Row Decoder
Defines `RowDecoder` for typed decoding from `Row`.
