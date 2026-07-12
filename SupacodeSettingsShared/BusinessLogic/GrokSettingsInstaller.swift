import Foundation

/// Top-level installer for Grok hooks. Owns a dedicated `~/.grok/hooks/supacode.json`
/// in the shared hooks dir (like Copilot's layout), but merges into it with the
/// Claude-style prune-and-replace installer, so user-authored hooks in that file survive.
nonisolated struct GrokSettingsInstaller {
  static let hookFileName = "supacode.json"

  let homeDirectoryURL: URL
  let fileManager: FileManager

  init(
    homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
    fileManager: FileManager = .default
  ) {
    self.homeDirectoryURL = homeDirectoryURL
    self.fileManager = fileManager
  }

  /// Install state for the unified hook map. See
  /// `ClaudeSettingsInstaller.installState()` for rationale.
  ///
  /// After the shared command-set check, also requires every managed hook to
  /// carry the canonical Grok env passthrough map, inspected on the same
  /// parsed snapshot (no second disk read).
  func installState() -> ComponentInstallState {
    let groups: [String: [JSONValue]]
    do {
      groups = try GrokHookSettings.hooksByEvent()
    } catch {
      Self.reportInvalidHookConfiguration(error)
      return .notInstalled
    }
    return fileInstaller.installState(
      settingsURL: settingsURL,
      hookGroupsByEvent: groups,
      additionalOutdatedIfInstalled: GrokHookSettings.managedHooksLackEnvPassthrough(in:)
    )
  }

  func installAllHooks() throws {
    try fileInstaller.install(
      settingsURL: settingsURL,
      hookGroupsByEvent: try GrokHookSettings.hooksByEvent()
    )
  }

  func uninstallAllHooks() throws {
    try fileInstaller.uninstall(
      settingsURL: settingsURL,
      hookGroupsByEvent: try GrokHookSettings.hooksByEvent()
    )
  }

  private static func reportInvalidHookConfiguration(_ error: Error) {
    #if DEBUG
      assertionFailure("Grok hook configuration is invalid: \(error)")
    #endif
  }

  private var settingsURL: URL {
    Self.settingsURL(homeDirectoryURL: homeDirectoryURL)
  }

  static func settingsURL(homeDirectoryURL: URL) -> URL {
    homeDirectoryURL
      .appending(path: ".grok", directoryHint: .isDirectory)
      .appending(path: "hooks", directoryHint: .isDirectory)
      .appending(path: hookFileName, directoryHint: .notDirectory)
  }

  private var fileInstaller: AgentHookSettingsFileInstaller {
    AgentHookSettingsFileInstaller(
      fileManager: fileManager,
      errors: .init(
        invalidEventHooks: { GrokSettingsInstallerError.invalidEventHooks($0) },
        invalidHooksObject: { GrokSettingsInstallerError.invalidHooksObject },
        invalidJSON: { GrokSettingsInstallerError.invalidJSON($0) },
        invalidRootObject: { GrokSettingsInstallerError.invalidRootObject }
      )
    )
  }
}

nonisolated enum GrokSettingsInstallerError: Error, Equatable, LocalizedError {
  case invalidEventHooks(String)
  case invalidHooksObject
  case invalidJSON(String)
  case invalidRootObject

  var errorDescription: String? {
    switch self {
    case .invalidEventHooks(let event):
      "Grok hooks use an unsupported shape for \(event)."
    case .invalidHooksObject:
      "Grok hooks use an unsupported shape."
    case .invalidJSON(let detail):
      "Grok hooks must be valid JSON before Supacode can install hooks (\(detail))."
    case .invalidRootObject:
      "Grok hooks must be a JSON object before Supacode can install hooks."
    }
  }
}
