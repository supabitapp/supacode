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

  func isInstalled(progress: Bool) -> Bool {
    let groups: [String: [JSONValue]]
    do {
      groups =
        try progress
        ? ClaudeHookSettings.progressHookGroupsByEvent()
        : ClaudeHookSettings.notificationHookGroupsByEvent()
    } catch {
      Self.reportInvalidHookConfiguration(error, progress: progress)
      return false
    }
    return fileInstaller.containsMatchingHooks(
      settingsURL: settingsURL,
      hookGroupsByEvent: groups
    )
  }

  func installProgressHooks() throws {
    try fileInstaller.install(
      settingsURL: settingsURL,
      hookGroupsByEvent: try ClaudeHookSettings.progressHookGroupsByEvent()
    )
  }

  func installNotificationHooks() throws {
    try fileInstaller.install(
      settingsURL: settingsURL,
      hookGroupsByEvent: try ClaudeHookSettings.notificationHookGroupsByEvent()
    )
  }

  func uninstallProgressHooks() throws {
    try fileInstaller.uninstall(
      settingsURL: settingsURL,
      hookGroupsByEvent: try ClaudeHookSettings.progressHookGroupsByEvent()
    )
  }

  func uninstallNotificationHooks() throws {
    try fileInstaller.uninstall(
      settingsURL: settingsURL,
      hookGroupsByEvent: try ClaudeHookSettings.notificationHookGroupsByEvent()
    )
  }

  private var settingsURL: URL {
    Self.settingsURL(homeDirectoryURL: homeDirectoryURL)
  }

  static func settingsURL(homeDirectoryURL: URL) -> URL {
    homeDirectoryURL
      .appendingPathComponent(".claude", isDirectory: true)
      .appendingPathComponent("settings.json", isDirectory: false)
  }

  private static func reportInvalidHookConfiguration(_ error: Error, progress: Bool) {
    #if DEBUG
      assertionFailure("Claude \(progress ? "progress" : "notification") hook configuration is invalid: \(error)")
    #endif
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
