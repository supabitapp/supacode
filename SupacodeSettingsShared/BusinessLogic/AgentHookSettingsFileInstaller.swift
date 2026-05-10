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
  func installState(
    settingsURL: URL,
    hookGroupsByEvent: [String: [JSONValue]]
  ) -> ComponentInstallState {
    do {
      let settingsObject = try loadSettingsObject(at: settingsURL)
      let expected = Self.commands(from: hookGroupsByEvent)
      guard !expected.isEmpty else { return .notInstalled }
      let actual = Self.installedSupacodeCommands(in: settingsObject)
      if actual.isEmpty { return .notInstalled }
      return actual == expected ? .installed : .outdated
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
    let settingsObject = try loadSettingsObject(at: settingsURL)
    var mergedObject = settingsObject
    var hooksObject = (mergedObject["hooks"]?.objectValue) ?? [:]
    for event in hooksObject.keys {
      let existing = try existingGroups(for: event, hooksObject: hooksObject)
      let filtered = existing.compactMap { stripAllSupacodeCommands(from: $0) }
      if filtered.isEmpty {
        hooksObject.removeValue(forKey: event)
      } else {
        hooksObject[event] = .array(filtered)
      }
    }
    mergedObject["hooks"] = .object(hooksObject)
    try writeSettings(mergedObject, to: settingsURL)
  }

  func install(
    settingsURL: URL,
    hookGroupsByEvent: @autoclosure () throws -> [String: [JSONValue]]
  ) throws {
    let settingsObject = try loadSettingsObject(at: settingsURL)
    let mergedObject = try mergedSettingsObject(
      from: settingsObject,
      hookGroupsByEvent: try hookGroupsByEvent()
    )
    try writeSettings(mergedObject, to: settingsURL)
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

  private func mergedSettingsObject(
    from settingsObject: [String: JSONValue],
    hookGroupsByEvent: [String: [JSONValue]]
  ) throws -> [String: JSONValue] {
    var mergedObject = settingsObject
    var hooksObject: [String: JSONValue]
    if let hooksValue = mergedObject["hooks"] {
      guard let existingHooksObject = hooksValue.objectValue else {
        throw errors.invalidHooksObject()
      }
      hooksObject = existingHooksObject
    } else {
      hooksObject = [:]
    }

    // Strip every Supacode-managed command across every event. The caller
    // passes the canonical (combined) hook set for the agent, so anything
    // Supacode-marked still in the file after this prune is a stale variant
    // from an older version that shouldn't survive the upgrade.
    for event in hooksObject.keys {
      let existing = try existingGroups(for: event, hooksObject: hooksObject)
      let filtered = existing.compactMap { stripAllSupacodeCommands(from: $0) }
      if filtered.isEmpty {
        hooksObject.removeValue(forKey: event)
      } else {
        hooksObject[event] = .array(filtered)
      }
    }

    // Add the canonical hooks 1:1.
    for (event, canonicalGroups) in hookGroupsByEvent {
      let existing = hooksObject[event]?.arrayValue ?? []
      hooksObject[event] = .array(existing + canonicalGroups)
    }

    mergedObject["hooks"] = .object(hooksObject)
    return mergedObject
  }

  private func existingGroups(
    for event: String,
    hooksObject: [String: JSONValue]
  ) throws -> [JSONValue] {
    guard let existingValue = hooksObject[event] else { return [] }
    guard let groups = existingValue.arrayValue else {
      throw errors.invalidEventHooks(event)
    }
    return groups
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
