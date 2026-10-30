public struct RowSmokeTest {
  public static func check() -> Bool {
    let r = Row(fields: [FieldValue(name: "id", value: .int64(7))])
    return r["id"] == .int64(7)
  }
}
