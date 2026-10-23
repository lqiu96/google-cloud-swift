# Implementation Plan: bigquery-demo
<!-- stack-plan:v1 -->

- repo: lqiu96/google-cloud-swift
- base: cascade-demo/main
- design_dir: doc/design/bigquery-demo
- branch_prefix: cascade-demo/
- test_cmd: CASCADE_PKGS=pkgs/swift-google-cloud-bigquery bash $HOME/.stacked-cascade/gates/swift-test.sh
- lint_cmd: CASCADE_PKGS=pkgs/swift-google-cloud-bigquery bash $HOME/.stacked-cascade/gates/swift-lint.sh

## Slices

| ID | Bookmark | Design Spec | Scope Fence | Depends On | Title |
|---|---|---|---|---|---|
| A | cascade-demo/bq-a | 04-values.md#scalar-types, 04-values.md#routine-data-types | `doc/design/bigquery-demo/**`, `pkgs/swift-google-cloud-bigquery/Sources/GoogleCloudBigQuery/BigNumeric.swift`, `pkgs/swift-google-cloud-bigquery/Sources/GoogleCloudBigQuery/CivilTypes.swift`, `pkgs/swift-google-cloud-bigquery/Sources/GoogleCloudBigQuery/Interval.swift`, `pkgs/swift-google-cloud-bigquery/Sources/GoogleCloudBigQuery/RoutineDataTypes.swift`, `pkgs/swift-google-cloud-bigquery/Tests/FieldValueTests.swift` | - | civil, numeric, and SQL types |
| B | cascade-demo/bq-b | 04-values.md#row-and-fieldvalue, 04-values.md#typed-accessors, 04-values.md#range-values, 04-values.md#row-sequence | `doc/design/bigquery-demo/**`, `pkgs/swift-google-cloud-bigquery/Sources/GoogleCloudBigQuery/BigQueryRange.swift`, `pkgs/swift-google-cloud-bigquery/Sources/GoogleCloudBigQuery/FieldValue+Accessors.swift`, `pkgs/swift-google-cloud-bigquery/Sources/GoogleCloudBigQuery/RowSequence.swift`, `pkgs/swift-google-cloud-bigquery/Sources/GoogleCloudBigQuery/Row.swift`, `pkgs/swift-google-cloud-bigquery/Tests/FieldValueTests.swift`, `pkgs/swift-google-cloud-bigquery/Tests/PagedSequenceTests.swift`, `pkgs/swift-google-cloud-bigquery/Tests/RowTests.swift` | A | Row, FieldValue, and range |
| C | cascade-demo/bq-c | 04-values.md#row-decoder | `doc/design/bigquery-demo/**`, `pkgs/swift-google-cloud-bigquery/Sources/GoogleCloudBigQuery/RowDecoder.swift`, `pkgs/swift-google-cloud-bigquery/Sources/GoogleCloudBigQuery/RowSequence+Decode.swift`, `pkgs/swift-google-cloud-bigquery/Tests/RowDecoderTests.swift` | A, B | Codable RowDecoder |

## Decisions Log

- 2026-10-23 PR -: distilled 3-slice team test stack (A -> B -> C) on cascade-demo/main.
