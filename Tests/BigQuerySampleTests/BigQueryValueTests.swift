public struct BigQueryValueSmokeTest {
  public static func check() -> Bool {
    BigQueryValue.int64(42) == .int64(42)
  }
}
