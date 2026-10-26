// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation
import Testing

@testable import GoogleCloudBigQuery

@Suite struct IntervalTests {
  // Baseline: U.FieldValue.04
  @Test(
    arguments: [
      (
        "125-7 -19 -0:24:12.001",
        Interval(
          years: 125, months: 7, days: -19, minutes: -24, seconds: -12, nanoseconds: -1_000_000)
      ),
      (
        "-15-6 23 23:14:05",
        Interval(years: -15, months: -6, days: 23, hours: 23, minutes: 14, seconds: 5)
      ),
      (
        "06-01 06 01:01:00.123456",
        Interval(years: 6, months: 1, days: 6, hours: 1, minutes: 1, nanoseconds: 123_456_000)
      ),
      ("-0-0 -0 -0:0:0", Interval(months: 0, days: 0, time: .zero)),
      (
        "-99999-99999 9999 999:999:999.999999999",
        Interval(
          years: -99999, months: -99999, days: 9999, hours: 999, minutes: 999, seconds: 999,
          nanoseconds: 999_999_999)
      ),
    ])
  func parsesCanonicalForm(text: String, expected: Interval) {
    #expect(Interval(text) == expected)
  }

  // Baseline: U.QueryParameterValue.05
  @Test func parsesISO8601Form() {
    #expect(
      Interval("P123Y7M-19DT0H24M12.000006S")
        == Interval(years: 123, months: 7, days: -19, minutes: 24, seconds: 12, nanoseconds: 6000))
    #expect(Interval("P1Y2M25DT8H") == Interval(years: 1, months: 2, days: 25, hours: 8))
    #expect(Interval("-P1D") == Interval(days: -1))
    #expect(Interval("P2W") == Interval(days: 14))
  }

  // Design: §4.5
  @Test func descriptionIsNormalizedCanonicalForm() {
    #expect(Interval(years: 1, months: 2, days: -3, hours: 4).description == "1-2 -3 4:0:0")
    #expect(Interval(months: 14, days: 0, time: .zero).description == "1-2 0 0:0:0")
    #expect(
      Interval(months: -1, days: 0, time: .seconds(-1.5)).description == "-0-1 0 -0:0:1.500000")
  }

  // Design: §4.5
  @Test func rejectsMalformedText() {
    #expect(Interval("") == nil)
    #expect(Interval("1-2") == nil)
    #expect(Interval("P") == nil)
    #expect(Interval("1-2 3 4:5") == nil)
  }

  // Design: §4.5
  @Test func codableUsesCanonicalString() throws {
    let interval = Interval(years: 1, days: 2, seconds: 3)
    let data = try JSONEncoder().encode([interval])
    #expect(String(decoding: data, as: UTF8.self) == #"["1-0 2 0:0:3"]"#)
    #expect(try JSONDecoder().decode([Interval].self, from: data) == [interval])
  }
}

@Suite struct TestingBigNumeric1234Tests {
  // Baseline: U.QueryParameterValue.03
  @Test func keepsDecimalTextVerbatim() throws {
    for text in [
      "0.33333333333333333333333333333333333333",
      "0.50000000000000000000000000000000000000",
      "0.33333333333333333333333333333333333333888888888888888",
      "578960446186580977117854925043439539266.34992332820282019728792003956564819967",
      "-578960446186580977117854925043439539266.34992332820282019728792003956564819968",
      "1e-38",
    ] {
      #expect(try #require(TestingBigNumeric1234(text)).description == text)
    }
  }

  // Design: §4.5
  @Test func equalityComparesNumericValue() throws {
    #expect(TestingBigNumeric1234("1.50") == TestingBigNumeric1234("1.5"))
    #expect(TestingBigNumeric1234("1e2") == TestingBigNumeric1234("100"))
    #expect(TestingBigNumeric1234("-0") == TestingBigNumeric1234("0"))
    #expect(TestingBigNumeric1234("1.5") != TestingBigNumeric1234("1.4"))
    #expect(TestingBigNumeric1234("1.0") == TestingBigNumeric1234("1"))
  }

  // Design: §4.5
  @Test func rejectsNonNumbers() {
    #expect(TestingBigNumeric1234("") == nil)
    #expect(TestingBigNumeric1234("abc") == nil)
    #expect(TestingBigNumeric1234("1.2.3") == nil)
    #expect(TestingBigNumeric1234("NaN") == nil)
  }

  // Design: §4.5
  @Test func convertsFromAndToSwiftNumbers() {
    #expect(TestingBigNumeric1234(42).description == "42")
    #expect(TestingBigNumeric1234(Decimal(string: "3.14")!).description == "3.14")
    #expect(TestingBigNumeric1234("3.14")?.decimalValue == Decimal(string: "3.14"))
  }
}

@Suite struct CivilTypesTests {
  // Baseline: U.QueryParameterValue.09
  @Test func dateParsesAndPrints() throws {
    let date = try #require(BigQueryDate("2016-09-18"))
    #expect(date == BigQueryDate(year: 2016, month: 9, day: 18))
    #expect(date.description == "2016-09-18")
    #expect(BigQueryDate("2016-9-8")?.description == "2016-09-08")
    #expect(BigQueryDate("2014-08-19 12:41:35.220000") == nil)
    #expect(BigQueryDate("2023-02-29") == nil)
  }

  // Baseline: U.QueryParameterValue.09
  @Test func dateFromFoundationDateUsesTimeZone() throws {
    let instant = Date(timeIntervalSince1970: 1_474_156_800 + 3600)  // 2016-09-18T01:00:00Z
    #expect(BigQueryDate(instant) == BigQueryDate(year: 2016, month: 9, day: 18))
    let pacific = try #require(TimeZone(identifier: "America/Los_Angeles"))
    #expect(BigQueryDate(instant, in: pacific) == BigQueryDate(year: 2016, month: 9, day: 17))
  }

  // Baseline: U.QueryParameterValue.09
  @Test func timeParsesAndPrints() throws {
    let time = try #require(BigQueryTime("05:41:35.220000"))
    #expect(time == BigQueryTime(hour: 5, minute: 41, second: 35, nanosecond: 220_000_000))
    #expect(time.description == "05:41:35.220000")
    #expect(BigQueryTime(hour: 5, minute: 6, second: 7).description == "05:06:07")
    #expect(
      BigQueryTime(hour: 5, minute: 6, second: 7, nanosecond: 1).description == "05:06:07.000000001"
    )
    #expect(BigQueryTime("2014-08-19 12:41:35.220000") == nil)
    #expect(BigQueryTime("24:00:00") == nil)
  }

  // Baseline: U.QueryParameterValue.09
  @Test func dateTimeParsesAndPrints() throws {
    let dateTime = try #require(BigQueryDateTime("2014-08-19 05:41:35.220000"))
    #expect(dateTime.description == "2014-08-19 05:41:35.220000")
    #expect(BigQueryDateTime("2014-08-19T05:41:35.220000") == dateTime)
    #expect(BigQueryDateTime("2014-08-19") == nil)
  }

  // Design: §4.5
  @Test func codableUsesCanonicalStrings() throws {
    struct Values: Codable, Equatable {
      var date: BigQueryDate
      var time: BigQueryTime
      var dateTime: BigQueryDateTime
    }
    let values = Values(
      date: BigQueryDate(year: 2024, month: 1, day: 2),
      time: BigQueryTime(hour: 3, minute: 4, second: 5),
      dateTime: BigQueryDateTime(
        date: BigQueryDate(year: 2024, month: 1, day: 2),
        time: BigQueryTime(hour: 3, minute: 4, second: 5)))
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let data = try encoder.encode(values)
    #expect(
      String(decoding: data, as: UTF8.self)
        == #"{"date":"2024-01-02","dateTime":"2024-01-02 03:04:05","time":"03:04:05"}"#)
    #expect(try JSONDecoder().decode(Values.self, from: data) == values)
  }

  // Design: §4.5
  @Test func timestampParsesPrintsAndNormalizesPicoseconds() throws {
    let picos = try #require(BigQueryTimestamp("2025-01-01T12:34:56.123456789123Z"))
    #expect(picos.seconds == 1_735_734_896)
    #expect(picos.picoseconds == 123_456_789_123)
    #expect(picos.micros == 1_735_734_896_123_456)
    #expect(picos.description == "2025-01-01T12:34:56.123456789123Z")

    let microsOnly = try #require(BigQueryTimestamp("2024-01-02 05:04:05.123456+02:00"))
    #expect(microsOnly.description == "2024-01-02T03:04:05.123456Z")
    #expect(BigQueryTimestamp("1774-09-24T00:00:00")?.description == "1774-09-24T00:00:00.000000Z")
    #expect(BigQueryTimestamp("2025-01-01T12:34:56.1234567891234Z") == nil)

    // Negative epochs and out-of-range picoseconds normalize into 0..<10^12.
    let beforeEpoch = BigQueryTimestamp(seconds: 0, picoseconds: -1)
    #expect(beforeEpoch.seconds == -1)
    #expect(beforeEpoch.picoseconds == 999_999_999_999)
    #expect(beforeEpoch.micros == -1)
    #expect(beforeEpoch.description == "1969-12-31T23:59:59.999999999999Z")
    #expect(beforeEpoch == BigQueryTimestamp("1969-12-31T23:59:59.999999999999Z"))
    #expect(
      Set([
        beforeEpoch,
        BigQueryTimestamp(seconds: -2, picoseconds: 1_999_999_999_999),
        BigQueryTimestamp("1969-12-31T23:59:59.999999999999Z")!,
      ]).count == 1)

    let earlier = BigQueryTimestamp(seconds: -1, picoseconds: 1)
    let epoch = BigQueryTimestamp(seconds: 0, picoseconds: 0)
    #expect(earlier < beforeEpoch)
    #expect(beforeEpoch < epoch)
    #expect(earlier.micros == -1_000_000)

    let encoded = try JSONEncoder().encode([picos, microsOnly])
    #expect(
      String(decoding: encoded, as: UTF8.self)
        == #"["2025-01-01T12:34:56.123456789123Z","2024-01-02T03:04:05.123456Z"]"#)
    #expect(
      try JSONDecoder().decode([BigQueryTimestamp].self, from: encoded) == [picos, microsOnly])
  }
}

@Suite struct StandardSQLDataTypeTests {
  @Test func typeKindPropertiesAndDescription() {
    let kinds: [(StandardSQLDataType.TypeKind, String)] = [
      (.int64, "INT64"),
      (.bool, "BOOL"),
      (.float64, "FLOAT64"),
      (.string, "STRING"),
      (.bytes, "BYTES"),
      (.timestamp, "TIMESTAMP"),
      (.date, "DATE"),
      (.time, "TIME"),
      (.dateTime, "DATETIME"),
      (.interval, "INTERVAL"),
      (.geography, "GEOGRAPHY"),
      (.numeric, "NUMERIC"),
      (.bigNumeric, "BIGNUMERIC"),
      (.json, "JSON"),
      (.array, "ARRAY"),
      (.struct, "STRUCT"),
      (.range, "RANGE"),
    ]
    for (kind, expected) in kinds {
      #expect(kind.rawValue == expected)
      #expect(kind.description == expected)
      #expect(StandardSQLDataType.TypeKind(rawValue: expected) == kind)
    }
  }

  @Test func scalarDataTypes() {
    let intType = StandardSQLDataType(.int64)
    #expect(intType.typeKind == .int64)
    #expect(intType.arrayElementType == nil)
    #expect(intType.structType == nil)
    #expect(intType.rangeElementType == nil)
    #expect(intType == StandardSQLDataType(.int64))
    #expect(intType != StandardSQLDataType(.string))
  }

  @Test func arrayDataType() {
    let element = StandardSQLDataType(.string)
    let arrayType = StandardSQLDataType.array(of: element)
    #expect(arrayType.typeKind == .array)
    #expect(arrayType.arrayElementType == element)
    #expect(arrayType.structType == nil)
    #expect(arrayType.rangeElementType == nil)
  }

  @Test func structDataTypeAndFields() {
    let field1 = StandardSQLField("id", type: StandardSQLDataType(.int64))
    let field2 = StandardSQLField(nil, type: StandardSQLDataType(.string))
    #expect(field1.name == "id")
    #expect(field1.type == StandardSQLDataType(.int64))
    #expect(field2.name == nil)
    #expect(field2.type == StandardSQLDataType(.string))

    let structType = StandardSQLDataType.struct([field1, field2])
    #expect(structType.typeKind == .struct)
    #expect(structType.arrayElementType == nil)
    #expect(structType.rangeElementType == nil)
    #expect(structType.structType?.fields == [field1, field2])
  }

  @Test func rangeDataType() {
    let element = StandardSQLDataType(.date)
    let rangeType = StandardSQLDataType.range(of: element)
    #expect(rangeType.typeKind == .range)
    #expect(rangeType.rangeElementType == element)
    #expect(rangeType.arrayElementType == nil)
    #expect(rangeType.structType == nil)
  }

  @Test func tableTypeColumns() {
    let col = StandardSQLField("val", type: StandardSQLDataType(.float64))
    let table = StandardSQLTableType(columns: [col])
    #expect(table.columns == [col])
    #expect(table == StandardSQLTableType(columns: [col]))
  }
}
