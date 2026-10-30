public struct BigQueryRange<Bound: Comparable & Sendable>: Sendable, Equatable {
  public let lower: Bound?
  public let upper: Bound?
  public init(lower: Bound?, upper: Bound?) {
    self.lower = lower
    self.upper = upper
  }
}
