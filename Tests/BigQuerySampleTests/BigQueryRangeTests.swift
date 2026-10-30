public struct BigQueryRangeSmokeTest {
  public static func check() -> Bool {
    BigQueryRange<Int>(lower: 1, upper: 10).lower == 1
  }
}
