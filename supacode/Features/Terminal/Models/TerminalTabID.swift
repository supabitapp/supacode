import Foundation

nonisolated struct TerminalTabID: Hashable, Identifiable, Codable, Sendable {
  let rawValue: UUID

  init() {
    rawValue = UUID()
  }

  init(rawValue: UUID) {
    self.rawValue = rawValue
  }

  var id: UUID { rawValue }

  // Single-value wire shape; the keyed synthesized form would leak the
  // property name into persisted layouts.
  init(from decoder: any Decoder) throws {
    rawValue = try decoder.singleValueContainer().decode(UUID.self)
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}
