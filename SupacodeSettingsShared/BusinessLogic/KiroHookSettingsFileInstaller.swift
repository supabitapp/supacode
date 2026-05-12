import Foundation

private nonisolated let kiroInstallerLogger = SupaLogger("Settings")

/// File installer for Kiro's flat hook format (`hooks → event → [{ command, timeout_ms }]`).
/// Unlike `AgentHookSettingsFileInstaller` which handles Claude/Codex grouped format.
nonisolated struct KiroHookSettingsFileInstaller {
  typealias Errors = JSONHookSettingsFile.Errors

  let fileManager: FileManager
  let errors: Errors
  let logWarning: @Sendable (String) -> Void

  init(
    fileManager: FileManager,
    errors: Errors,
    logWarning: @escaping @Sendable (String) -> Void = { kiroInstallerLogger.warning($0) }
  ) {
    self.fileManager = fileManager
    self.errors = errors
    self.logWarning = logWarning
  }

  private var file: JSONHookSettingsFile {
    JSONHookSettingsFile(fileManager: fileManager, errors: errors)
  }

  // MARK: - Check.

  func installState(
    settingsURL: URL,
    hookEntriesByEvent: [String: [JSONValue]]
  ) -> ComponentInstallState {
    do {
      let settingsObject = try loadSettingsObject(at: settingsURL)
      let expected = Self.commands(from: hookEntriesByEvent)
      guard !expected.isEmpty else { return .notInstalled }
      let actual = Self.installedSupacodeCommands(in: settingsObject)
      if actual.isEmpty { return .notInstalled }
      return actual == expected ? .installed : .outdated
    } catch {
      if !Self.isFileNotFound(error) {
        logWarning("Failed to inspect Kiro hook settings at \(settingsURL.path): \(error)")
      }
      return .notInstalled
    }
  }

  private static func installedSupacodeCommands(
    in settingsObject: [String: JSONValue]
  ) -> Set<String> {
    guard let hooksObject = settingsObject["hooks"]?.objectValue else { return [] }
    var commands = Set<String>()
    for (_, value) in hooksObject {
      guard let entries = value.arrayValue else { continue }
      for entry in entries {
        guard let entryObject = entry.objectValue,
          let command = entryObject["command"]?.stringValue,
          AgentHookCommandOwnership.isSupacodeManagedCommand(command)
        else { continue }
        commands.insert(command)
      }
    }
    return commands
  }

  // MARK: - Install.

  /// `install = uninstall + append`: strip every Supacode-managed entry,
  /// then append the canonical entries 1:1. See
  /// `AgentHookSettingsFileInstaller.install` for the rationale.
  func install(
    settingsURL: URL,
    hookEntriesByEvent: @autoclosure () throws -> [String: [JSONValue]]
  ) throws {
    let canonicalEntries = try hookEntriesByEvent()
    var settingsObject = try loadSettingsObject(at: settingsURL)
    let existing = try existingHooksObject(in: settingsObject)
    var pruned = try pruneAllSupacodeEntries(from: existing)
    for (event, entries) in canonicalEntries {
      let existingEntries = pruned[event]?.arrayValue ?? []
      pruned[event] = .array(existingEntries + entries)
    }
    settingsObject["hooks"] = .object(pruned)
    try writeSettings(settingsObject, to: settingsURL)
  }

  // MARK: - Uninstall.

  func uninstall(
    settingsURL: URL,
    hookEntriesByEvent: @autoclosure () throws -> [String: [JSONValue]]
  ) throws {
    _ = try hookEntriesByEvent()  // Eval for parity with `install` errors.
    var settingsObject = try loadSettingsObject(at: settingsURL)
    let existing = try existingHooksObject(in: settingsObject)
    let pruned = try pruneAllSupacodeEntries(from: existing)
    settingsObject["hooks"] = .object(pruned)
    try writeSettings(settingsObject, to: settingsURL)
  }

  // MARK: - Helpers.

  private static func commands(from hookEntriesByEvent: [String: [JSONValue]]) -> Set<String> {
    var commands = Set<String>()
    for (_, entries) in hookEntriesByEvent {
      for entry in entries {
        guard let entryObject = entry.objectValue,
          let command = entryObject["command"]?.stringValue
        else { continue }
        commands.insert(command)
      }
    }
    return commands
  }

  private static func isManaged(_ entry: JSONValue) -> Bool {
    guard let entryObject = entry.objectValue,
      let command = entryObject["command"]?.stringValue
    else { return false }
    return AgentHookCommandOwnership.isSupacodeManagedCommand(command)
  }

  /// Builds a fresh hooks map with every Supacode-managed entry stripped.
  /// Iterates the source dict (never mutates while iterating) so the prune
  /// can't silently skip an event.
  private func pruneAllSupacodeEntries(
    from hooksObject: [String: JSONValue]
  ) throws -> [String: JSONValue] {
    var result: [String: JSONValue] = [:]
    for (event, value) in hooksObject {
      guard let entries = value.arrayValue else {
        throw errors.invalidEventHooks(event)
      }
      let filtered = entries.filter { !Self.isManaged($0) }
      if !filtered.isEmpty {
        result[event] = .array(filtered)
      }
    }
    return result
  }

  private func existingHooksObject(
    in settingsObject: [String: JSONValue]
  ) throws -> [String: JSONValue] {
    guard let hooksValue = settingsObject["hooks"] else { return [:] }
    guard let hooksObject = hooksValue.objectValue else {
      throw errors.invalidHooksObject()
    }
    return hooksObject
  }

  private func loadSettingsObject(at url: URL) throws -> [String: JSONValue] {
    try file.load(at: url)
  }

  private func writeSettings(_ object: [String: JSONValue], to url: URL) throws {
    try file.write(object, to: url)
  }

  private static func isFileNotFound(_ error: Error) -> Bool {
    JSONHookSettingsFile.isFileNotFound(error)
  }
}
