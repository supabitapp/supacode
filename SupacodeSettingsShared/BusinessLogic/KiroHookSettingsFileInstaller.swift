import Foundation

private nonisolated let kiroInstallerLogger = SupaLogger("Settings")

/// File installer for Kiro's flat hook format (`hooks → event → [{ command, timeout_ms }]`).
/// Unlike `AgentHookSettingsFileInstaller` which handles Claude/Codex grouped format.
nonisolated struct KiroHookSettingsFileInstaller {
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
    logWarning: @escaping @Sendable (String) -> Void = { kiroInstallerLogger.warning($0) }
  ) {
    self.fileManager = fileManager
    self.errors = errors
    self.logWarning = logWarning
  }

  // MARK: - Check.

  func containsMatchingHooks(
    settingsURL: URL,
    hookEntriesByEvent: [String: [JSONValue]]
  ) -> Bool {
    do {
      let settingsObject = try loadSettingsObject(at: settingsURL)
      guard let hooksObject = settingsObject["hooks"]?.objectValue else { return false }
      let expectedCommands = Self.commands(from: hookEntriesByEvent)
      guard !expectedCommands.isEmpty else { return false }
      for (_, value) in hooksObject {
        guard let entries = value.arrayValue else { continue }
        for entry in entries {
          guard let entryObject = entry.objectValue,
            let command = entryObject["command"]?.stringValue
          else { continue }
          if expectedCommands.contains(command) { return true }
        }
      }
      return false
    } catch {
      if !Self.isFileNotFound(error) {
        logWarning("Failed to inspect Kiro hook settings at \(settingsURL.path): \(error)")
      }
      return false
    }
  }

  // MARK: - Install.

  func install(
    settingsURL: URL,
    hookEntriesByEvent: @autoclosure () throws -> [String: [JSONValue]]
  ) throws {
    let settingsObject = try loadSettingsObject(at: settingsURL)
    let hookEntries = try hookEntriesByEvent()
    let commandsToPrune = Self.commands(from: hookEntries)
    var mergedObject = settingsObject
    var hooksObject = try existingHooksObject(in: mergedObject)

    // Remove existing managed commands before re-adding.
    for event in hooksObject.keys {
      let existing = try existingEntries(for: event, hooksObject: hooksObject)
      let filtered = existing.filter { !Self.isManaged($0, commands: commandsToPrune) }
      if filtered.isEmpty {
        hooksObject.removeValue(forKey: event)
      } else {
        hooksObject[event] = .array(filtered)
      }
    }

    for (event, newEntries) in hookEntries {
      let existing = hooksObject[event]?.arrayValue ?? []
      hooksObject[event] = .array(existing + newEntries)
    }

    mergedObject["hooks"] = .object(hooksObject)
    try writeSettings(mergedObject, to: settingsURL)
  }

  // MARK: - Uninstall.

  func uninstall(
    settingsURL: URL,
    hookEntriesByEvent: @autoclosure () throws -> [String: [JSONValue]]
  ) throws {
    let settingsObject = try loadSettingsObject(at: settingsURL)
    let commandsToPrune = Self.commands(from: try hookEntriesByEvent())
    var mergedObject = settingsObject
    var hooksObject = try existingHooksObject(in: mergedObject)

    for event in hooksObject.keys {
      let existing = try existingEntries(for: event, hooksObject: hooksObject)
      let filtered = existing.filter { !Self.isManaged($0, commands: commandsToPrune) }
      if filtered.isEmpty {
        hooksObject.removeValue(forKey: event)
      } else {
        hooksObject[event] = .array(filtered)
      }
    }

    mergedObject["hooks"] = .object(hooksObject)
    try writeSettings(mergedObject, to: settingsURL)
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

  private static func isManaged(_ entry: JSONValue, commands: Set<String>) -> Bool {
    guard let entryObject = entry.objectValue,
      let command = entryObject["command"]?.stringValue
    else { return false }
    if commands.contains(command) { return true }
    return AgentHookCommandOwnership.isLegacyCommand(command)
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

  private func existingEntries(
    for event: String,
    hooksObject: [String: JSONValue]
  ) throws -> [JSONValue] {
    guard let existingValue = hooksObject[event] else { return [] }
    guard let entries = existingValue.arrayValue else {
      throw errors.invalidEventHooks(event)
    }
    return entries
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

  private static func isFileNotFound(_ error: Error) -> Bool {
    let nsError = error as NSError
    return nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError
  }
}
