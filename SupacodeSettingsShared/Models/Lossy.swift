import Foundation

/// Wrapper that always succeeds at the container level,
/// capturing decode failures as `nil` instead of throwing.
nonisolated struct Lossy<T: Decodable & Sendable>: Decodable, Sendable {
  let value: T?
  init(from decoder: Decoder) throws {
    value = try? T(from: decoder)
  }
}
