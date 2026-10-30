# Implementation Plan: bigquery-e2e

- repo: lqiu96/google-cloud-swift
- base: cascade-e2e/main
- design_dir: doc/design/bigquery-e2e
- branch_prefix: cascade-e2e/
- test_cmd: CASCADE_PKGS=pkgs/swift-google-cloud-bigquery bash $HOME/.stacked-cascade/gates/swift-lint.sh
- lint_cmd: CASCADE_PKGS=pkgs/swift-google-cloud-bigquery bash $HOME/.stacked-cascade/gates/swift-lint.sh

## Slices

| ID | Bookmark | Design Spec | Scope Fence | Depends On | Title |
|---|---|---|---|---|---|
| A | cascade-e2e/bq-a | DESIGN.md#scalar-types | `doc/design/bigquery-e2e/**`, `pkgs/swift-google-cloud-bigquery/Sources/GoogleCloudBigQuery/BigNumeric.swift`, `pkgs/swift-google-cloud-bigquery/Sources/GoogleCloudBigQuery/CivilTypes.swift`, `pkgs/swift-google-cloud-bigquery/Sources/GoogleCloudBigQuery/Interval.swift`, `pkgs/swift-google-cloud-bigquery/Sources/GoogleCloudBigQuery/RoutineDataTypes.swift`, `pkgs/swift-google-cloud-bigquery/Tests/FieldValueTests.swift` | - | civil, numeric, and SQL types |
| B | cascade-e2e/bq-b | DESIGN.md#row-and-fieldvalue | `doc/design/bigquery-e2e/**`, `pkgs/swift-google-cloud-bigquery/Sources/GoogleCloudBigQuery/BigQueryRange.swift`, `pkgs/swift-google-cloud-bigquery/Sources/GoogleCloudBigQuery/FieldValue+Accessors.swift`, `pkgs/swift-google-cloud-bigquery/Sources/GoogleCloudBigQuery/RowSequence.swift`, `pkgs/swift-google-cloud-bigquery/Sources/GoogleCloudBigQuery/Row.swift`, `pkgs/swift-google-cloud-bigquery/Tests/FieldValueTests.swift`, `pkgs/swift-google-cloud-bigquery/Tests/PagedSequenceTests.swift`, `pkgs/swift-google-cloud-bigquery/Tests/RowTests.swift` | A | Row, FieldValue, and range |
| C | cascade-e2e/bq-c | DESIGN.md#row-decoder | `doc/design/bigquery-e2e/**`, `pkgs/swift-google-cloud-bigquery/Sources/GoogleCloudBigQuery/RowDecoder.swift`, `pkgs/swift-google-cloud-bigquery/Sources/GoogleCloudBigQuery/RowSequence+Decode.swift`, `pkgs/swift-google-cloud-bigquery/Tests/RowDecoderTests.swift` | A, B | Codable RowDecoder |
