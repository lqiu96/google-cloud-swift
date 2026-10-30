# Implementation Plan: bq-reshape-e2e

- repo: lqiu96/google-cloud-swift
- base: cascade-reshape/base
- design_dir: doc/design/bq-reshape-e2e
- branch_prefix: cascade-reshape/
- test_cmd: test -d Sources/BigQuerySample
- lint_cmd: true

## Slices

| ID | Bookmark | Design Spec | Scope Fence | Depends On | Title |
|---|---|---|---|---|---|
| A | cascade-reshape/01-types | DESIGN.md#core-types | `doc/design/bq-reshape-e2e/**`, `Sources/BigQuerySample/BigQueryValue.swift`, `Tests/BigQuerySampleTests/BigQueryValueTests.swift` | - | feat(bigquery): add core BigQueryValue types |
| B | cascade-reshape/02-rows | DESIGN.md#row-model | `Sources/BigQuerySample/Row.swift`, `Tests/BigQuerySampleTests/RowTests.swift` | A | feat(bigquery): add Row model |
