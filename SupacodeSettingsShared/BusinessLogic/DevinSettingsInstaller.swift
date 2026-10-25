import Foundation

/// Top-level installer for Devin hooks. Merges the Supacode hook map into the
/// `"hooks"` key of `~/.config/devin/config.json` — Devin's main settings file,
/// so the shared prune-and-replace installer must preserve every sibling key
/// (model, permissions, …) it doesn't own.
nonisolated struct DevinSettingsInstaller {
  let configDirectoryURL: URL
  let fileManager: FileManager

  init(
    homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
    configDirectoryURL: URL? = nil,
    fileManager: FileManager = .default
  ) {
    self.configDirectoryURL =
      configDirectoryURL
      ?? homeDirectoryURL.appending(path: ".config/devin", directoryHint: .isDirectory)
    self.fileManager = fileManager
  }

  /// Install state for the unified hook map. The file installer's prune
  /// step covers every event the integration writes, eliminating stale
  /// duplicates left by older Supacode versions.
  func installState() throws -> ComponentInstallState {
    let groups: [String: [JSONValue]]
    do {
      groups = try DevinHookSettings.hooksByEvent()
    } catch {
      Self.reportInvalidHookConfiguration(error)
      return .notInstalled
    }
    return try fileInstaller.installState(settingsURL: settingsURL, hookGroupsByEvent: groups)
  }

  func installAllHooks() throws {
    try fileInstaller.install(
      settingsURL: settingsURL,
      hookGroupsByEvent: try DevinHookSettings.hooksByEvent()
    )
  }

  func uninstallAllHooks() throws {
    try fileInstaller.uninstall(
      settingsURL: settingsURL,
      hookGroupsByEvent: try DevinHookSettings.hooksByEvent()
    )
  }

  private static func reportInvalidHookConfiguration(_ error: Error) {
    #if DEBUG
      assertionFailure("Devin hook configuration is invalid: \(error)")
    #endif
  }

  private var settingsURL: URL {
    configDirectoryURL.appending(path: "config.json", directoryHint: .notDirectory)
  }

  static func settingsURL(homeDirectoryURL: URL) -> URL {
    homeDirectoryURL
      .appending(path: ".config/devin", directoryHint: .isDirectory)
      .appending(path: "config.json", directoryHint: .notDirectory)
  }

  private var fileInstaller: AgentHookSettingsFileInstaller {
    AgentHookSettingsFileInstaller(
      fileManager: fileManager,
      errors: .init(
        invalidEventHooks: { DevinSettingsInstallerError.invalidEventHooks($0) },
        invalidHooksObject: { DevinSettingsInstallerError.invalidHooksObject },
        invalidJSON: { DevinSettingsInstallerError.invalidJSON($0) },
        invalidRootObject: { DevinSettingsInstallerError.invalidRootObject }
      )
    )
  }
}

nonisolated enum DevinSettingsInstallerError: Error, Equatable, LocalizedError {
  case invalidEventHooks(String)
  case invalidHooksObject
  case invalidJSON(String)
  case invalidRootObject

  var errorDescription: String? {
    switch self {
    case .invalidEventHooks(let event):
      "Devin config uses an unsupported hooks shape for \(event)."
    case .invalidHooksObject:
      "Devin config uses an unsupported hooks shape."
    case .invalidJSON(let detail):
      "Devin config must be valid JSON before Supacode can install hooks (\(detail))."
    case .invalidRootObject:
      "Devin config must be a JSON object before Supacode can install hooks."
    }
  }
}
