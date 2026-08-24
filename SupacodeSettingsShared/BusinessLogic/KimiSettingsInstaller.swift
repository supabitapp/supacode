import Foundation

/// Top-level installer for Kimi Code hooks. Owns the canonical entry list
/// (`KimiHookSettings`) and delegates the on-disk TOML read-modify-write to
/// `KimiHookSettingsFileInstaller`. Kimi activates hooks purely from
/// `~/.kimi-code/config.toml`, so there is no version probe and no feature flag.
nonisolated struct KimiSettingsInstaller {
  let configDirectoryURL: URL
  let fileManager: FileManager

  init(
    homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
    configDirectoryURL: URL? = nil,
    fileManager: FileManager = .default,
  ) {
    self.configDirectoryURL =
      configDirectoryURL ?? homeDirectoryURL.appending(path: ".kimi-code", directoryHint: .isDirectory)
    self.fileManager = fileManager
  }

  /// Install state for the unified hook map. See
  /// `ClaudeSettingsInstaller.installState()` for rationale.
  func installState() throws -> ComponentInstallState {
    let entries = KimiHookSettings.canonicalEntries()
    return try fileInstaller.installState(
      settingsURL: settingsURL,
      canonicalEntries: entries,
    )
  }

  func installAllHooks() throws {
    let entries = KimiHookSettings.canonicalEntries()
    try fileInstaller.install(settingsURL: settingsURL, canonicalEntries: entries)
  }

  func uninstallAllHooks() throws {
    let entries = KimiHookSettings.canonicalEntries()
    try fileInstaller.uninstall(settingsURL: settingsURL, canonicalEntries: entries)
  }

  // MARK: - Paths.

  private var settingsURL: URL {
    configDirectoryURL.appending(path: "config.toml", directoryHint: .notDirectory)
  }

  static func settingsURL(homeDirectoryURL: URL) -> URL {
    homeDirectoryURL
      .appendingPathComponent(".kimi-code", isDirectory: true)
      .appendingPathComponent("config.toml", isDirectory: false)
  }

  private var fileInstaller: KimiHookSettingsFileInstaller {
    KimiHookSettingsFileInstaller(fileManager: fileManager)
  }
}
