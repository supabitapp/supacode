import Foundation

private nonisolated let antigravityInstallerLogger = SupaLogger("Settings")

/// Manages hook installation for Antigravity CLI.
///
/// Note: Unlike agents using the standard grouped `hooks` schema (handled by `AgentHookSettingsFileInstaller`),
/// Antigravity uses a top-level `"supacode-hooks"` namespace in `~/.gemini/config/hooks.json` with a flat
/// event-to-command array layout, plus feature toggles in `~/.gemini/antigravity-cli/settings.json`.
/// Therefore, this installer uses a custom file management implementation.
nonisolated struct AntigravitySettingsInstaller {
  let homeDirectoryURL: URL
  let fileManager: FileManager

  init(
    homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
    fileManager: FileManager = .default
  ) {
    self.homeDirectoryURL = homeDirectoryURL
    self.fileManager = fileManager
  }

  private static let supacodeHooksKey = "supacode-hooks"
  private static let enableJSONHooksSnakeKey = "enable_json_hooks"
  private static let enableJSONHooksCamelKey = "enableJsonHooks"

  // Historical root-level event names a prior Supacode version may have written before the
  // `supacode-hooks` namespace existed. Intentionally frozen and kept independent of the canonical
  // Antigravity events (names may overlap; these match at the JSON root, not under `supacode-hooks`).
  private static let legacyEvents = [
    "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
    "Notification", "PreCompact", "Stop", "SessionEnd",
  ]

  /// Normalize an event value to its hook entries: an array, or a single hook object; scalar and null have none.
  private static func hookEntries(in value: JSONValue?) -> [JSONValue] {
    guard let value else { return [] }
    if let array = value.arrayValue { return array }
    if value.objectValue != nil { return [value] }
    return []
  }

  /// The event's entries whose command is not Supacode-managed (mirror of `containsSupacodeHook`).
  private static func extractUserHooks(from jsonValue: JSONValue?) -> [JSONValue] {
    hookEntries(in: jsonValue).filter { hookValue in
      guard let command = hookValue.objectValue?["command"]?.stringValue else { return true }
      return !AgentHookCommandOwnership.isSupacodeManagedCommand(command)
    }
  }

  private static func containsSupacodeHook(in jsonValue: JSONValue?) -> Bool {
    hookEntries(in: jsonValue).contains { hookValue in
      guard let command = hookValue.objectValue?["command"]?.stringValue else { return false }
      return AgentHookCommandOwnership.isSupacodeManagedCommand(command)
    }
  }

  private static func pruneLegacyEvents(from rootObject: inout [String: JSONValue]) {
    for event in legacyEvents {
      guard containsSupacodeHook(in: rootObject[event]) else { continue }
      let userHooks = extractUserHooks(from: rootObject[event])
      if userHooks.isEmpty {
        rootObject.removeValue(forKey: event)
      } else {
        rootObject[event] = .array(userHooks)
      }
    }
  }

  private static func hasLegacySupacodeHooks(in rootObject: [String: JSONValue]) -> Bool {
    legacyEvents.contains { containsSupacodeHook(in: rootObject[$0]) }
  }

  /// Read the `supacode-hooks` namespace. Refuses a present-but-non-object value rather than
  /// silently overwriting configuration Supacode does not own.
  private static func supacodeHooksObject(in rootObject: [String: JSONValue]) throws -> [String: JSONValue] {
    guard let value = rootObject[supacodeHooksKey] else { return [:] }
    guard let object = value.objectValue else {
      throw AntigravitySettingsInstallerError.invalidHooksObject
    }
    return object
  }

  /// Reject scalar or null event values under `supacode-hooks`; only arrays or single hook objects are valid.
  private static func validateEventShapes(in supacodeHooks: [String: JSONValue]) throws {
    for (event, value) in supacodeHooks where value.arrayValue == nil && value.objectValue == nil {
      throw AntigravitySettingsInstallerError.invalidEventHooks(event)
    }
  }

  private static func featureTogglesEnabled(in mainSettingsObject: [String: JSONValue]?) -> Bool {
    guard let mainSettingsObject else { return false }
    return mainSettingsObject[enableJSONHooksSnakeKey]?.boolValue == true
      || mainSettingsObject[enableJSONHooksCamelKey]?.boolValue == true
  }

  func installState() -> ComponentInstallState {
    guard fileManager.fileExists(atPath: settingsURL.path) else { return .notInstalled }

    do {
      let rootObject = try file.load(at: settingsURL)

      // Legacy root-level Supacode hooks mean a stale install that must be migrated.
      if Self.hasLegacySupacodeHooks(in: rootObject) { return .outdated }

      // No managed hooks anywhere means the integration was never installed, regardless of the
      // feature toggles. Checking presence before the toggles keeps a user's own pre-existing
      // `hooks.json` from being reported `.outdated` and auto-installed over without consent.
      guard let supacodeHooks = rootObject[Self.supacodeHooksKey]?.objectValue else {
        return .notInstalled
      }
      // A malformed event shape can't be cleanly managed: install and uninstall reject it, so it
      // must not read as installed here.
      do {
        try Self.validateEventShapes(in: supacodeHooks)
      } catch {
        antigravityInstallerLogger.warning(
          "Antigravity supacode-hooks has an unsupported shape at \(settingsURL.path): \(error)")
        return .notInstalled
      }
      let actualByEvent = Self.actualSupacodeCommandsByEvent(in: supacodeHooks)
      guard !actualByEvent.isEmpty else { return .notInstalled }

      guard Self.featureTogglesEnabled(in: loadMainSettingsForStateCheck()) else {
        return .outdated
      }
      let expectedByEvent = Self.expectedCommandsByEvent(from: AntigravityHookSettings.hooksByEvent())
      guard !expectedByEvent.isEmpty else { return .notInstalled }
      return actualByEvent == expectedByEvent ? .installed : .outdated
    } catch {
      if !JSONHookSettingsFile.isFileNotFound(error) {
        antigravityInstallerLogger.warning("Failed to inspect Antigravity hooks at \(settingsURL.path): \(error)")
      }
      return .notInstalled
    }
  }

  /// Load the main settings for a read-only state probe, logging (rather than throwing on) a corrupt
  /// file so a bad `settings.json` surfaces in the logs instead of silently reading as unset flags.
  private func loadMainSettingsForStateCheck() -> [String: JSONValue]? {
    do {
      return try file.load(at: mainSettingsURL)
    } catch {
      if !JSONHookSettingsFile.isFileNotFound(error) {
        antigravityInstallerLogger.warning(
          "Failed to inspect Antigravity settings at \(mainSettingsURL.path): \(error)")
      }
      return nil
    }
  }

  /// Canonical Supacode commands per event. Comparing per event (not a flattened set) is required
  /// because several events intentionally share a command (`Pre*` use busy, `Post*` use idle), so a
  /// flattened set cannot tell a removed event apart from a survivor with the same command.
  private static func expectedCommandsByEvent(from groups: [String: [JSONValue]]) -> [String: Set<String>] {
    var byEvent: [String: Set<String>] = [:]
    for (event, hooks) in groups {
      let commands = Set(hooks.compactMap { $0.objectValue?["command"]?.stringValue })
      if !commands.isEmpty { byEvent[event] = commands }
    }
    return byEvent
  }

  private static func actualSupacodeCommandsByEvent(in supacodeHooks: [String: JSONValue]) -> [String: Set<String>] {
    var byEvent: [String: Set<String>] = [:]
    for (event, value) in supacodeHooks {
      let commands = Set(
        hookEntries(in: value)
          .compactMap { $0.objectValue?["command"]?.stringValue }
          .filter { AgentHookCommandOwnership.isSupacodeManagedCommand($0) })
      if !commands.isEmpty { byEvent[event] = commands }
    }
    return byEvent
  }

  func installAllHooks() throws {
    var rootObject = try file.load(at: settingsURL)

    Self.pruneLegacyEvents(from: &rootObject)

    let existingSupacodeHooks = try Self.supacodeHooksObject(in: rootObject)
    try Self.validateEventShapes(in: existingSupacodeHooks)

    var supacodeHooks: [String: JSONValue] = [:]
    let canonicalGroupsByEvent = AntigravityHookSettings.hooksByEvent()

    for (event, canonicalHooks) in canonicalGroupsByEvent {
      var merged = Self.extractUserHooks(from: existingSupacodeHooks[event])
      for hook in canonicalHooks where hook != .null {
        merged.append(hook)
      }
      if !merged.isEmpty {
        supacodeHooks[event] = .array(merged)
      }
    }

    for (event, value) in existingSupacodeHooks where supacodeHooks[event] == nil {
      let userHooks = Self.extractUserHooks(from: value)
      if !userHooks.isEmpty {
        supacodeHooks[event] = .array(userHooks)
      }
    }

    if !supacodeHooks.isEmpty {
      rootObject[Self.supacodeHooksKey] = .object(supacodeHooks)
    } else {
      rootObject.removeValue(forKey: Self.supacodeHooksKey)
    }

    try file.write(rootObject, to: settingsURL)

    var mainSettingsObject = try file.load(at: mainSettingsURL)
    // Set both snake_case and camelCase flags for compatibility across Antigravity CLI versions.
    mainSettingsObject[Self.enableJSONHooksSnakeKey] = .bool(true)
    mainSettingsObject[Self.enableJSONHooksCamelKey] = .bool(true)
    try file.write(mainSettingsObject, to: mainSettingsURL)
  }

  func uninstallAllHooks() throws {
    var rootObject: [String: JSONValue]
    do {
      rootObject = try file.load(at: settingsURL)
    } catch {
      if JSONHookSettingsFile.isFileNotFound(error) {
        try removeMainSettingsFlagsIfNoHooksRemain(hooksRemain: false)
        return
      }
      throw error
    }

    if rootObject[Self.supacodeHooksKey] != nil {
      var supacodeHooks = try Self.supacodeHooksObject(in: rootObject)
      try Self.validateEventShapes(in: supacodeHooks)
      for (event, value) in supacodeHooks {
        guard Self.containsSupacodeHook(in: value) else { continue }
        let filtered = Self.extractUserHooks(from: value)
        if filtered.isEmpty {
          supacodeHooks.removeValue(forKey: event)
        } else {
          supacodeHooks[event] = .array(filtered)
        }
      }
      if !supacodeHooks.isEmpty {
        rootObject[Self.supacodeHooksKey] = .object(supacodeHooks)
      } else {
        rootObject.removeValue(forKey: Self.supacodeHooksKey)
      }
    }

    Self.pruneLegacyEvents(from: &rootObject)

    let hooksRemain = !rootObject.isEmpty
    if rootObject.isEmpty {
      // Let a failed delete surface: swallowing it would report a clean uninstall while the
      // `supacode-hooks` block still lives on disk.
      if fileManager.fileExists(atPath: settingsURL.path) {
        try fileManager.removeItem(at: settingsURL)
      }
    } else {
      try file.write(rootObject, to: settingsURL)
    }

    try removeMainSettingsFlagsIfNoHooksRemain(hooksRemain: hooksRemain)
  }

  private func removeMainSettingsFlagsIfNoHooksRemain(hooksRemain: Bool) throws {
    guard !hooksRemain, fileManager.fileExists(atPath: mainSettingsURL.path) else { return }

    var mainSettingsObject: [String: JSONValue]
    do {
      mainSettingsObject = try file.load(at: mainSettingsURL)
    } catch {
      // Corrupt main settings: leave the flags orphaned rather than fail the whole uninstall
      // (harmless once hooks.json is gone), but log at error since this mutation didn't complete.
      antigravityInstallerLogger.error(
        "Failed to strip Antigravity hook flags at \(mainSettingsURL.path): \(error)")
      return
    }

    mainSettingsObject.removeValue(forKey: Self.enableJSONHooksSnakeKey)
    mainSettingsObject.removeValue(forKey: Self.enableJSONHooksCamelKey)
    if mainSettingsObject.isEmpty {
      try fileManager.removeItem(at: mainSettingsURL)
    } else {
      try file.write(mainSettingsObject, to: mainSettingsURL)
    }
  }

  private var file: JSONHookSettingsFile {
    JSONHookSettingsFile(
      fileManager: fileManager,
      errors: .init(
        invalidEventHooks: { AntigravitySettingsInstallerError.invalidEventHooks($0) },
        invalidHooksObject: { AntigravitySettingsInstallerError.invalidHooksObject },
        invalidJSON: { AntigravitySettingsInstallerError.invalidJSON($0) },
        invalidRootObject: { AntigravitySettingsInstallerError.invalidRootObject }
      )
    )
  }

  private var settingsURL: URL {
    Self.settingsURL(homeDirectoryURL: homeDirectoryURL)
  }

  static func settingsURL(homeDirectoryURL: URL) -> URL {
    homeDirectoryURL
      .appending(path: ".gemini/config", directoryHint: .isDirectory)
      .appending(path: "hooks.json", directoryHint: .notDirectory)
  }

  private var mainSettingsURL: URL {
    Self.mainSettingsURL(homeDirectoryURL: homeDirectoryURL)
  }

  static func mainSettingsURL(homeDirectoryURL: URL) -> URL {
    homeDirectoryURL
      .appending(path: ".gemini/antigravity-cli", directoryHint: .isDirectory)
      .appending(path: "settings.json", directoryHint: .notDirectory)
  }
}

nonisolated enum AntigravitySettingsInstallerError: Error, Equatable, LocalizedError {
  case invalidEventHooks(String)
  case invalidHooksObject
  case invalidJSON(String)
  case invalidRootObject

  var errorDescription: String? {
    switch self {
    case .invalidEventHooks(let event):
      "Antigravity settings use an unsupported hooks shape for \(event)."
    case .invalidHooksObject:
      "Antigravity settings use an unsupported hooks shape."
    case .invalidJSON(let detail):
      "Antigravity settings must be valid JSON before Supacode can install hooks (\(detail))."
    case .invalidRootObject:
      "Antigravity settings must be a JSON object before Supacode can install hooks."
    }
  }
}
