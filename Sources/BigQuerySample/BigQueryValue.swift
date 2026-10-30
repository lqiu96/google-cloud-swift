public enum BigQueryType: String, Sendable, Equatable {
  case string = "STRING"
  case int64 = "INT64"
}
public enum BigQueryValue: Sendable, Equatable {
  case null
  case string(String)
  case int64(Int64)
}
