public struct RowDecoderSmokeTest {
  public static func check() -> Bool {
    let r = Row(fields: [FieldValue(name: "n", value: .int64(99))])
    return RowDecoder.decodeInt64(r, field: "n") == 99
  }
}
