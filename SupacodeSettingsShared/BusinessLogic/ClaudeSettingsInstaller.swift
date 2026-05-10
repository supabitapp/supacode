import Foundation

nonisolated struct ClaudeSettingsInstaller {
  let homeDirectoryURL: URL
  let fileManager: FileManager

  init(
    homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
    fileManager: FileManager = .default
  ) {
    self.homeDirectoryURL = homeDirectoryURL
    self.fileManager = fileManager
  }

  /// Combined progress + notification install state. Used by the unified
  /// integration so the file installer's prune step covers every event the
  /// integration writes — eliminating stale duplicates left by older
  /// Supacode versions.
  func installState() -> ComponentInstallState {
    let groups: [String: [JSONValue]]
    do {
      groups = try ClaudeHookSettings.allHooksByEvent()
    } catch {
      Self.reportInvalidAllHookConfiguration(error)
      return .notInstalled
    }
    return fileInstaller.installState(settingsURL: settingsURL, hookGroupsByEvent: groups)
  }

  func installAllHooks() throws {
    try fileInstaller.install(
      settingsURL: settingsURL,
      hookGroupsByEvent: try ClaudeHookSettings.allHooksByEvent()
    )
  }

  func uninstallAllHooks() throws {
    try fileInstaller.uninstall(
      settingsURL: settingsURL,
      hookGroupsByEvent: try ClaudeHookSettings.allHooksByEvent()
    )
  }

  private static func reportInvalidAllHookConfiguration(_ error: Error) {
    #if DEBUG
      assertionFailure("Claude hook configuration is invalid: \(error)")
    #endif
  }

  private var settingsURL: URL {
    Self.settingsURL(homeDirectoryURL: homeDirectoryURL)
  }

  static func settingsURL(homeDirectoryURL: URL) -> URL {
    homeDirectoryURL
      .appendingPathComponent(".claude", isDirectory: true)
      .appendingPathComponent("settings.json", isDirectory: false)
  }

  private var fileInstaller: AgentHookSettingsFileInstaller {
    AgentHookSettingsFileInstaller(
      fileManager: fileManager,
      errors: .init(
        invalidEventHooks: { ClaudeSettingsInstallerError.invalidEventHooks($0) },
        invalidHooksObject: { ClaudeSettingsInstallerError.invalidHooksObject },
        invalidJSON: { ClaudeSettingsInstallerError.invalidJSON($0) },
        invalidRootObject: { ClaudeSettingsInstallerError.invalidRootObject }
      )
    )
  }
}

nonisolated enum ClaudeSettingsInstallerError: Error, Equatable, LocalizedError {
  case invalidEventHooks(String)
  case invalidHooksObject
  case invalidJSON(String)
  case invalidRootObject

  var errorDescription: String? {
    switch self {
    case .invalidEventHooks(let event):
      "Claude settings use an unsupported hooks shape for \(event)."
    case .invalidHooksObject:
      "Claude settings use an unsupported hooks shape."
    case .invalidJSON(let detail):
      "Claude settings must be valid JSON before Supacode can install hooks (\(detail))."
    case .invalidRootObject:
      "Claude settings must be a JSON object before Supacode can install hooks."
    }
  }
}
