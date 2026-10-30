public struct RowDecoder: Sendable {
  public static func decodeInt64(_ row: Row, field: String) -> Int64? {
    guard case .int64(let v)? = row[field] else { return nil }
    return v
  }
}
