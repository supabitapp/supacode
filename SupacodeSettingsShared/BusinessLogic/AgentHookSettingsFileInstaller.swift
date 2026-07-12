import Foundation

private nonisolated let settingsInstallerLogger = SupaLogger("Settings")

nonisolated struct AgentHookSettingsFileInstaller {
  typealias Errors = JSONHookSettingsFile.Errors

  let fileManager: FileManager
  let errors: Errors
  let logWarning: @Sendable (String) -> Void

  init(
    fileManager: FileManager,
    errors: Errors,
    logWarning: @escaping @Sendable (String) -> Void = { settingsInstallerLogger.warning($0) }
  ) {
    self.fileManager = fileManager
    self.errors = errors
    self.logWarning = logWarning
  }

  private var file: JSONHookSettingsFile {
    JSONHookSettingsFile(fileManager: fileManager, errors: errors)
  }

  /// Compare the set of Supacode-managed commands present in the settings
  /// file against the expected (canonical) set:
  /// - `.installed`     — actual Supacode commands == expected, no extras
  /// - `.notInstalled`  — no Supacode-managed commands at all
  /// - `.outdated`      — some present, but the set differs (extras, missing,
  ///                      or stale variants from older Supacode versions)
  ///
  /// `additionalOutdatedIfInstalled` runs only when the command set already
  /// matches, against the **same** parsed snapshot (no second disk read). Use
  /// it for non-command payload checks such as Grok's env passthrough map.
  func installState(
    settingsURL: URL,
    hookGroupsByEvent: [String: [JSONValue]],
    additionalOutdatedIfInstalled: (([String: JSONValue]) -> Bool)? = nil
  ) -> ComponentInstallState {
    do {
      let settingsObject = try loadSettingsObject(at: settingsURL)
      let expected = Self.commands(from: hookGroupsByEvent)
      guard !expected.isEmpty else { return .notInstalled }
      let actual = Self.installedSupacodeCommands(in: settingsObject)
      if actual.isEmpty { return .notInstalled }
      guard actual == expected else { return .outdated }
      if let additionalOutdatedIfInstalled, additionalOutdatedIfInstalled(settingsObject) {
        return .outdated
      }
      return .installed
    } catch {
      if !Self.isFileNotFound(error) {
        logWarning("Failed to inspect hook settings at \(settingsURL.path): \(error)")
      }
      return .notInstalled
    }
  }

  /// All Supacode-marked `command` strings under the `hooks` map. Filters
  /// via `AgentHookCommandOwnership` so user-authored hooks are never
  /// treated as "ours."
  private static func installedSupacodeCommands(
    in settingsObject: [String: JSONValue]
  ) -> Set<String> {
    guard let hooksValue = settingsObject["hooks"],
      let hooksObject = hooksValue.objectValue
    else { return [] }
    var commands = Set<String>()
    for (_, value) in hooksObject {
      guard let groups = value.arrayValue else { continue }
      for group in groups {
        guard let groupObject = group.objectValue,
          let hooks = groupObject["hooks"]?.arrayValue
        else { continue }
        for hook in hooks {
          guard let hookObject = hook.objectValue,
            let command = hookObject["command"]?.stringValue,
            AgentHookCommandOwnership.isSupacodeManagedCommand(command)
          else { continue }
          commands.insert(command)
        }
      }
    }
    return commands
  }

  private static func commands(from hookGroupsByEvent: [String: [JSONValue]]) -> Set<String> {
    var commands = Set<String>()
    for (_, groups) in hookGroupsByEvent {
      for group in groups {
        guard let groupObject = group.objectValue,
          let hooks = groupObject["hooks"]?.arrayValue
        else { continue }
        for hook in hooks {
          guard let hookObject = hook.objectValue,
            let command = hookObject["command"]?.stringValue
          else { continue }
          commands.insert(command)
        }
      }
    }
    return commands
  }

  /// Removes every Supacode-managed command (current and legacy) from the
  /// settings file. User-authored hooks are preserved — the trailing
  /// `# supacode-managed-hook` sentinel is the source of truth for
  /// ownership (see `AgentHookCommandOwnership`).
  func uninstall(
    settingsURL: URL,
    hookGroupsByEvent: @autoclosure () throws -> [String: [JSONValue]]
  ) throws {
    _ = try hookGroupsByEvent()  // Eval for parity with `install` errors; we don't use the value.
    var settingsObject = try loadSettingsObject(at: settingsURL)
    // Symmetric with `install`: refuse to overwrite a non-object `hooks`
    // value (would silently destroy user data we don't own).
    if let hooksValue = settingsObject["hooks"], hooksValue.objectValue == nil {
      throw errors.invalidHooksObject()
    }
    let hooksObject = settingsObject["hooks"]?.objectValue ?? [:]
    let pruned = try pruneAllSupacodeCommands(from: hooksObject)
    settingsObject["hooks"] = .object(pruned)
    try writeSettings(settingsObject, to: settingsURL)
  }

  /// `install = uninstall + append`: strip every Supacode-managed entry from
  /// the existing hook map (current + legacy + pre-collapse splits), then
  /// append the canonical groups 1:1. Done in a single read-modify-write so
  /// a crash mid-update can't leave the file half-pruned.
  func install(
    settingsURL: URL,
    hookGroupsByEvent: @autoclosure () throws -> [String: [JSONValue]]
  ) throws {
    let canonicalGroups = try hookGroupsByEvent()
    var settingsObject = try loadSettingsObject(at: settingsURL)
    if let hooksValue = settingsObject["hooks"], hooksValue.objectValue == nil {
      throw errors.invalidHooksObject()
    }
    let existing = settingsObject["hooks"]?.objectValue ?? [:]
    var pruned = try pruneAllSupacodeCommands(from: existing)
    for (event, groups) in canonicalGroups {
      let existingGroups = pruned[event]?.arrayValue ?? []
      pruned[event] = .array(existingGroups + groups)
    }
    settingsObject["hooks"] = .object(pruned)
    try writeSettings(settingsObject, to: settingsURL)
  }

  /// Builds a fresh hooks map with every Supacode-managed command
  /// stripped. Builds a new dict instead of mutating while iterating, to
  /// guarantee no event is silently skipped during the prune.
  private func pruneAllSupacodeCommands(
    from hooksObject: [String: JSONValue]
  ) throws -> [String: JSONValue] {
    var result: [String: JSONValue] = [:]
    for (event, value) in hooksObject {
      guard let groups = value.arrayValue else {
        throw errors.invalidEventHooks(event)
      }
      let filtered = groups.compactMap { stripAllSupacodeCommands(from: $0) }
      if !filtered.isEmpty {
        result[event] = .array(filtered)
      }
    }
    return result
  }

  private func writeSettings(_ object: [String: JSONValue], to url: URL) throws {
    try file.write(object, to: url)
  }

  private func loadSettingsObject(at url: URL) throws -> [String: JSONValue] {
    try file.load(at: url)
  }

  private static func isFileNotFound(_ error: Error) -> Bool {
    JSONHookSettingsFile.isFileNotFound(error)
  }

  /// Strip every Supacode-managed command from the group. User-authored
  /// hooks (no `# supacode-managed-hook` sentinel) survive untouched.
  private func stripAllSupacodeCommands(from group: JSONValue) -> JSONValue? {
    guard var groupObject = group.objectValue else { return group }
    guard let hooksValue = groupObject["hooks"] else { return group }
    guard let hooks = hooksValue.arrayValue else { return group }
    let filteredHooks = hooks.filter { hook in
      guard let hookObject = hook.objectValue,
        let command = hookObject["command"]?.stringValue
      else { return true }
      return !AgentHookCommandOwnership.isSupacodeManagedCommand(command)
    }
    guard !filteredHooks.isEmpty else { return nil }
    groupObject["hooks"] = .array(filteredHooks)
    return .object(groupObject)
  }
}
