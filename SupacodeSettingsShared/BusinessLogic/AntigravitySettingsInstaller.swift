import Foundation

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

  private static let legacyEvents = [
    "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
    "Notification", "PreCompact", "Stop", "SessionEnd",
  ]

  private static func extractUserHooks(from jsonValue: JSONValue?) -> [JSONValue] {
    guard let jsonValue else { return [] }
    if let array = jsonValue.arrayValue {
      return array.filter { hookValue in
        guard let hookObj = hookValue.objectValue,
          let command = hookObj["command"]?.stringValue
        else { return true }
        return !AgentHookCommandOwnership.isSupacodeManagedCommand(command)
      }
    } else if let hookObj = jsonValue.objectValue {
      if let command = hookObj["command"]?.stringValue,
        AgentHookCommandOwnership.isSupacodeManagedCommand(command)
      {
        return []
      }
      return [jsonValue]
    } else if jsonValue != .null {
      return [jsonValue]
    }
    return []
  }

  private static func containsSupacodeHook(in jsonValue: JSONValue?) -> Bool {
    guard let jsonValue else { return false }
    if let array = jsonValue.arrayValue {
      return array.contains { hookValue in
        guard let command = hookValue.objectValue?["command"]?.stringValue else { return false }
        return AgentHookCommandOwnership.isSupacodeManagedCommand(command)
      }
    } else if let hookObj = jsonValue.objectValue,
      let command = hookObj["command"]?.stringValue
    {
      return AgentHookCommandOwnership.isSupacodeManagedCommand(command)
    }
    return false
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
    for event in legacyEvents {
      if let hooksArray = rootObject[event]?.arrayValue {
        for hookValue in hooksArray {
          if let command = hookValue.objectValue?["command"]?.stringValue,
            AgentHookCommandOwnership.isSupacodeManagedCommand(command)
          {
            return true
          }
        }
      } else if let hookObj = rootObject[event]?.objectValue {
        if let command = hookObj["command"]?.stringValue,
          AgentHookCommandOwnership.isSupacodeManagedCommand(command)
        {
          return true
        }
      }
    }
    return false
  }

  func installState() -> ComponentInstallState {
    guard fileManager.fileExists(atPath: settingsURL.path) else { return .notInstalled }
    guard let mainSettingsObject = try? file.load(at: mainSettingsURL) else { return .outdated }

    let flag1 = mainSettingsObject["enable_json_hooks"]?.boolValue == true
    let flag2 = mainSettingsObject["enableJsonHooks"]?.boolValue == true
    guard flag1 || flag2 else { return .outdated }

    do {
      let rootObject = try file.load(at: settingsURL)
      if Self.hasLegacySupacodeHooks(in: rootObject) {
        return .outdated
      }

      guard let supacodeHooks = rootObject["supacode-hooks"]?.objectValue else {
        return .notInstalled
      }

      let canonicalGroupsByEvent = AntigravityHookSettings.hooksByEvent()
      let expectedCommands = Self.expectedCommands(from: canonicalGroupsByEvent)
      guard !expectedCommands.isEmpty else { return .notInstalled }

      let actualCommands = Self.actualSupacodeCommands(in: supacodeHooks)
      if actualCommands.isEmpty { return .notInstalled }
      return actualCommands == expectedCommands ? .installed : .outdated
    } catch {
      if !JSONHookSettingsFile.isFileNotFound(error) {
        Self.reportInvalidHookConfiguration(error)
      }
      return .notInstalled
    }
  }

  private static func expectedCommands(from groups: [String: [JSONValue]]) -> Set<String> {
    var commands: Set<String> = []
    for (_, hooks) in groups {
      for hook in hooks {
        if let command = hook.objectValue?["command"]?.stringValue {
          commands.insert(command)
        }
      }
    }
    return commands
  }

  private static func actualSupacodeCommands(in supacodeHooks: [String: JSONValue]) -> Set<String> {
    var commands: Set<String> = []
    for (_, value) in supacodeHooks {
      if let hooksArray = value.arrayValue {
        for hook in hooksArray {
          if let command = hook.objectValue?["command"]?.stringValue,
            AgentHookCommandOwnership.isSupacodeManagedCommand(command)
          {
            commands.insert(command)
          }
        }
      } else if let hookObj = value.objectValue,
        let command = hookObj["command"]?.stringValue,
        AgentHookCommandOwnership.isSupacodeManagedCommand(command)
      {
        commands.insert(command)
      }
    }
    return commands
  }

  func installAllHooks() throws {
    var rootObject = try file.load(at: settingsURL)

    Self.pruneLegacyEvents(from: &rootObject)

    var supacodeHooks: [String: JSONValue] = [:]
    let canonicalGroupsByEvent = AntigravityHookSettings.hooksByEvent()
    let existingSupacodeHooks = rootObject["supacode-hooks"]?.objectValue ?? [:]

    for (event, canonicalHooks) in canonicalGroupsByEvent {
      var merged: [JSONValue] = []
      let existingUserHooks = Self.extractUserHooks(from: existingSupacodeHooks[event])
      merged.append(contentsOf: existingUserHooks)
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
      rootObject["supacode-hooks"] = .object(supacodeHooks)
    } else {
      rootObject.removeValue(forKey: "supacode-hooks")
    }

    try file.write(rootObject, to: settingsURL)

    var mainSettingsObject = try file.load(at: mainSettingsURL)
    // Set both snake_case and camelCase flags for compatibility across Antigravity CLI versions.
    mainSettingsObject["enable_json_hooks"] = .bool(true)
    mainSettingsObject["enableJsonHooks"] = .bool(true)
    try file.write(mainSettingsObject, to: mainSettingsURL)
  }

  func uninstallAllHooks() throws {
    var rootObject: [String: JSONValue]
    do {
      rootObject = try file.load(at: settingsURL)
    } catch {
      if JSONHookSettingsFile.isFileNotFound(error) {
        removeMainSettingsFlagsIfNoHooksRemain(hooksRemain: false)
        return
      }
      throw error
    }

    if var supacodeHooks = rootObject["supacode-hooks"]?.objectValue {
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
        rootObject["supacode-hooks"] = .object(supacodeHooks)
      } else {
        rootObject.removeValue(forKey: "supacode-hooks")
      }
    }

    Self.pruneLegacyEvents(from: &rootObject)

    let hooksRemain = !rootObject.isEmpty
    if rootObject.isEmpty {
      try? fileManager.removeItem(at: settingsURL)
    } else {
      try file.write(rootObject, to: settingsURL)
    }

    removeMainSettingsFlagsIfNoHooksRemain(hooksRemain: hooksRemain)
  }

  private func removeMainSettingsFlagsIfNoHooksRemain(hooksRemain: Bool) {
    guard !hooksRemain,
      var mainSettingsObject = try? file.load(at: mainSettingsURL)
    else { return }

    mainSettingsObject.removeValue(forKey: "enable_json_hooks")
    mainSettingsObject.removeValue(forKey: "enableJsonHooks")
    if mainSettingsObject.isEmpty {
      try? fileManager.removeItem(at: mainSettingsURL)
    } else {
      try? file.write(mainSettingsObject, to: mainSettingsURL)
    }
  }

  private static func reportInvalidHookConfiguration(_ error: Error) {
    #if DEBUG
      assertionFailure("Antigravity hook configuration is invalid: \(error)")
    #endif
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
