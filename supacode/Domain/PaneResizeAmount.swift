nonisolated enum PaneResizeAmount: Equatable, Sendable {
  case points(UInt16)
  case ratio(Double)

  static let ratioRange = 0.1...0.9
}
