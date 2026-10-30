public struct FieldValue: Sendable, Equatable {
  public let name: String
  public let value: BigQueryValue
}
public struct Row: Sendable, Equatable {
  public let fields: [FieldValue]
  public subscript(name: String) -> BigQueryValue? {
    fields.first(where: { $0.name == name })?.value
  }
}
