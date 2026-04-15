import Foundation

private nonisolated let settingsInstallerLogger = SupaLogger("Settings")

nonisolated struct AgentHookSettingsFileInstaller {
  struct Errors {
    let invalidEventHooks: @Sendable (String) -> Error
    let invalidHooksObject: @Sendable () -> Error
    let invalidJSON: @Sendable (String) -> Error
    let invalidRootObject: @Sendable () -> Error
  }

  private enum LoadError: Error {
    case invalidRootObject
  }

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

  /// Returns `true` when at least one command from the given hook groups
  /// is present in the settings file.
  func containsMatchingHooks(
    settingsURL: URL,
    hookGroupsByEvent: [String: [JSONValue]]
  ) -> Bool {
    do {
      let settingsObject = try loadSettingsObject(at: settingsURL)
      guard let hooksValue = settingsObject["hooks"],
        let hooksObject = hooksValue.objectValue
      else {
        return false
      }
      let expectedCommands = Self.commands(from: hookGroupsByEvent)
      guard !expectedCommands.isEmpty else { return false }
      for (_, value) in hooksObject {
        guard let groups = value.arrayValue else { continue }
        for group in groups {
          guard let groupObject = group.objectValue,
            let hooks = groupObject["hooks"]?.arrayValue
          else { continue }
          for hook in hooks {
            guard let hookObject = hook.objectValue,
              let command = hookObject["command"]?.stringValue
            else { continue }
            if expectedCommands.contains(command) { return true }
          }
        }
      }
      return false
    } catch {
      if !Self.isFileNotFound(error) {
        logWarning("Failed to inspect hook settings at \(settingsURL.path): \(error)")
      }
      return false
    }
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

  /// Removes matching hooks and any legacy Supacode-owned commands.
  func uninstall(
    settingsURL: URL,
    hookGroupsByEvent: @autoclosure () throws -> [String: [JSONValue]]
  ) throws {
    let settingsObject = try loadSettingsObject(at: settingsURL)
    let commandsToPrune = Self.commands(from: try hookGroupsByEvent())
    var mergedObject = settingsObject
    var hooksObject = (mergedObject["hooks"]?.objectValue) ?? [:]
    for event in hooksObject.keys {
      let existing = try existingGroups(for: event, hooksObject: hooksObject)
      let filtered = existing.compactMap { prunedGroup($0, removing: commandsToPrune) }
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
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(JSONValue.object(object))
    try data.write(to: url, options: .atomic)
  }

  private func loadSettingsObject(at url: URL) throws -> [String: JSONValue] {
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

  private static func isFileNotFound(_ error: Error) -> Bool {
    let nsError = error as NSError
    return nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError
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

    // Only prune commands that belong to the feature being installed
    // (or uninstalled). This preserves hooks from other features.
    let commandsToPrune = Self.commands(from: hookGroupsByEvent)
    for event in hooksObject.keys {
      let existing = try existingGroups(for: event, hooksObject: hooksObject)
      let filtered = existing.compactMap { prunedGroup($0, removing: commandsToPrune) }
      if filtered.isEmpty {
        hooksObject.removeValue(forKey: event)
      } else {
        hooksObject[event] = .array(filtered)
      }
    }

    // Add the new hooks.
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

  private func prunedGroup(_ group: JSONValue, removing commandsToPrune: Set<String>) -> JSONValue? {
    guard var groupObject = group.objectValue else { return group }
    guard let hooksValue = groupObject["hooks"] else { return group }
    guard let hooks = hooksValue.arrayValue else { return group }
    let filteredHooks = hooks.filter { hook in
      guard let hookObject = hook.objectValue,
        let command = hookObject["command"]?.stringValue
      else { return true }
      // Remove if it matches the specific feature being installed,
      // or if it's a legacy Supacode command.
      if commandsToPrune.contains(command) { return false }
      if AgentHookCommandOwnership.isLegacyCommand(command) { return false }
      return true
    }
    guard !filteredHooks.isEmpty else { return nil }
    groupObject["hooks"] = .array(filteredHooks)
    return .object(groupObject)
  }
}
