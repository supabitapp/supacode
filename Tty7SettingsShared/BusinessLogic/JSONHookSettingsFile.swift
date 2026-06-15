import Foundation

/// Shared JSON file IO for hook installers (`AgentHookSettingsFileInstaller`,
/// `KiroHookSettingsFileInstaller`). Both speak the same on-disk shape — a
/// JSON object at the root with a top-level `"hooks"` key — and only differ
/// in the per-event hook entry shape (Claude/Codex grouped vs Kiro flat).
nonisolated struct JSONHookSettingsFile {
  struct Errors {
    let invalidEventHooks: @Sendable (String) -> Error
    let invalidHooksObject: @Sendable () -> Error
    let invalidJSON: @Sendable (String) -> Error
    let invalidRootObject: @Sendable () -> Error
  }

  let fileManager: FileManager
  let errors: Errors

  /// Read and decode the settings file at `url`. Returns `[:]` when the
  /// file doesn't exist (a fresh user install). Throws via `errors` for
  /// malformed JSON or non-object roots.
  func load(at url: URL) throws -> [String: JSONValue] {
    guard fileManager.fileExists(atPath: url.path) else { return [:] }
    let data = try Data(contentsOf: url)
    do {
      let jsonValue = try JSONDecoder().decode(JSONValue.self, from: data)
      guard let object = jsonValue.objectValue else {
        throw LoadError.invalidRootObject
      }
      return object
    } catch LoadError.invalidRootObject {
      throw errors.invalidRootObject()
    } catch {
      throw errors.invalidJSON(error.localizedDescription)
    }
  }

  /// Pretty-print and atomically write the settings object to `url`.
  /// Creates the parent directory if missing.
  func write(_ object: [String: JSONValue], to url: URL) throws {
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(JSONValue.object(object))
    try data.write(to: url, options: .atomic)
  }

  /// True for the file-not-found error that `load(at:)` will never throw
  /// (it returns `[:]`) but that callers may surface from other reads —
  /// e.g. probe paths that don't yet exist on a fresh machine.
  static func isFileNotFound(_ error: Error) -> Bool {
    let nsError = error as NSError
    return nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError
  }

  private enum LoadError: Error {
    case invalidRootObject
  }
}
