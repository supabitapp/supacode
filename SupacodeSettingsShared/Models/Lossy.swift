import Foundation

private nonisolated let lossyLogger = SupaLogger("Settings")

/// Element wrapper that captures decode failures as `nil` instead of throwing,
/// so a single malformed entry doesn't abort the whole array.
nonisolated struct Lossy<T: Decodable & Sendable>: Decodable, Sendable {
  let value: T?
  init(from decoder: Decoder) throws {
    do {
      value = try T(from: decoder)
    } catch {
      // Avoid `\(error)` — `DecodingError`'s description embeds raw values and
      // would leak user-defined names / commands to the unified log.
      lossyLogger.warning("Dropped malformed \(T.self) entry (decode error).")
      value = nil
    }
  }
}

extension KeyedDecodingContainer {
  /// Returns `nil` when `key` is absent (caller can trigger legacy migration),
  /// `[]` when the key is present but the array is malformed, and `[T]`
  /// otherwise — element failures are logged and dropped.
  public nonisolated func decodeLossyArrayIfPresent<T: Decodable & Sendable>(
    _ type: [T].Type = [T].self,
    forKey key: Key
  ) -> [T]? {
    guard contains(key) else { return nil }
    guard let wrappers = try? decode([Lossy<T>].self, forKey: key) else {
      lossyLogger.warning("Could not decode lossy array at '\(key.stringValue)'; returning empty.")
      return []
    }
    return wrappers.compactMap(\.value)
  }

  /// Like `decodeLossyArrayIfPresent`, but also reports the ORIGINAL indices of
  /// dropped elements so callers can remap positional fields (e.g. a persisted
  /// selected-index) into the surviving array's coordinate space.
  public nonisolated func decodeLossyArrayWithDroppedIndices<T: Decodable & Sendable>(
    _ type: [T].Type = [T].self,
    forKey key: Key
  ) -> (elements: [T], droppedIndices: [Int])? {
    guard contains(key) else { return nil }
    guard let wrappers = try? decode([Lossy<T>].self, forKey: key) else {
      lossyLogger.warning("Could not decode lossy array at '\(key.stringValue)'; returning empty.")
      return ([], [])
    }
    var elements: [T] = []
    var droppedIndices: [Int] = []
    for (index, wrapper) in wrappers.enumerated() {
      if let value = wrapper.value {
        elements.append(value)
      } else {
        droppedIndices.append(index)
      }
    }
    return (elements, droppedIndices)
  }
}
