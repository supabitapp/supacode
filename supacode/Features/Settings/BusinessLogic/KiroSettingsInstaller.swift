import Foundation

nonisolated struct KiroSettingsInstaller {
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
    let entries: [String: [JSONValue]]
    do {
      entries =
        try progress
        ? KiroHookSettings.progressHookEntriesByEvent()
        : KiroHookSettings.notificationHookEntriesByEvent()
    } catch {
      Self.reportInvalidHookConfiguration(error, progress: progress)
      return false
    }
    return fileInstaller.containsMatchingHooks(
      settingsURL: settingsURL,
      hookEntriesByEvent: entries
    )
  }

  func installProgressHooks() throws {
    try ensureDefaultAgentConfig()
    try fileInstaller.install(
      settingsURL: settingsURL,
      hookEntriesByEvent: try KiroHookSettings.progressHookEntriesByEvent()
    )
  }

  func installNotificationHooks() throws {
    try ensureDefaultAgentConfig()
    try fileInstaller.install(
      settingsURL: settingsURL,
      hookEntriesByEvent: try KiroHookSettings.notificationHookEntriesByEvent()
    )
  }

  func uninstallProgressHooks() throws {
    try fileInstaller.uninstall(
      settingsURL: settingsURL,
      hookEntriesByEvent: try KiroHookSettings.progressHookEntriesByEvent()
    )
  }

  func uninstallNotificationHooks() throws {
    try fileInstaller.uninstall(
      settingsURL: settingsURL,
      hookEntriesByEvent: try KiroHookSettings.notificationHookEntriesByEvent()
    )
  }

  // MARK: - Default agent config.

  /// Creates `kiro_default.json` with the known built-in defaults when the file does not exist.
  private func ensureDefaultAgentConfig() throws {
    guard !fileManager.fileExists(atPath: settingsURL.path) else { return }
    try fileManager.createDirectory(
      at: settingsURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let defaultConfig: [String: JSONValue] = [
      "name": .string("kiro_default"),
      "tools": .array([.string("*")]),
      "resources": .array([
        .string("file://AGENTS.md"),
        .string("file://README.md"),
        .string("skill://.kiro/skills/**/SKILL.md"),
        .string("skill://.kiro/steering/**/*.md"),
      ]),
      "useLegacyMcpJson": .bool(true),
      "hooks": .object([:]),
    ]
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(JSONValue.object(defaultConfig))
    try data.write(to: settingsURL, options: .atomic)
  }

  // MARK: - Paths.

  private var settingsURL: URL {
    Self.settingsURL(homeDirectoryURL: homeDirectoryURL)
  }

  static func settingsURL(homeDirectoryURL: URL) -> URL {
    homeDirectoryURL
      .appendingPathComponent(".kiro", isDirectory: true)
      .appendingPathComponent("agents", isDirectory: true)
      .appendingPathComponent("kiro_default.json", isDirectory: false)
  }

  private static func reportInvalidHookConfiguration(_ error: Error, progress: Bool) {
    #if DEBUG
      assertionFailure("Kiro \(progress ? "progress" : "notification") hook configuration is invalid: \(error)")
    #endif
  }

  private var fileInstaller: KiroHookSettingsFileInstaller {
    KiroHookSettingsFileInstaller(
      fileManager: fileManager,
      errors: .init(
        invalidEventHooks: { KiroSettingsInstallerError.invalidEventHooks($0) },
        invalidHooksObject: { KiroSettingsInstallerError.invalidHooksObject },
        invalidJSON: { KiroSettingsInstallerError.invalidJSON($0) },
        invalidRootObject: { KiroSettingsInstallerError.invalidRootObject }
      )
    )
  }
}

nonisolated enum KiroSettingsInstallerError: Error, Equatable, LocalizedError {
  case invalidEventHooks(String)
  case invalidHooksObject
  case invalidJSON(String)
  case invalidRootObject

  var errorDescription: String? {
    switch self {
    case .invalidEventHooks(let event):
      "Kiro agent config uses an unsupported hooks shape for \(event)."
    case .invalidHooksObject:
      "Kiro agent config uses an unsupported hooks shape."
    case .invalidJSON(let detail):
      "Kiro agent config must be valid JSON before Supacode can install hooks (\(detail))."
    case .invalidRootObject:
      "Kiro agent config must be a JSON object before Supacode can install hooks."
    }
  }
}
