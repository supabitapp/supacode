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
  /// file doesn't exist (a fresh user install). Throws `AgentFileUnreadableError`
  /// when it exists but can't be read, and via `errors` for malformed JSON or
  /// non-object roots.
  func load(at url: URL) throws -> [String: JSONValue] {
    guard let data = try AgentFileProbe.data(at: url) else { return [:] }
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

  /// True for a genuine file-not-found. `load(at:)` resolves absence to `[:]`
  /// rather than throwing, so callers keep this only as a defensive guard on
  /// errors reaching them from elsewhere.
  static func isFileNotFound(_ error: Error) -> Bool {
    AgentFileProbe.isFileNotFound(error)
  }

  private enum LoadError: Error {
    case invalidRootObject
  }
}
