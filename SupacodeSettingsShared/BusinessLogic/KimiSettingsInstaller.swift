import Foundation

/// Top-level installer for Kimi CLI hooks. Owns the canonical entry list
/// (`KimiHookSettings`) and delegates the on-disk TOML read-modify-write to
/// `KimiHookSettingsFileInstaller`. Kimi activates hooks purely from
/// `~/.kimi/config.toml`, so there is no version probe and no feature flag.
nonisolated struct KimiSettingsInstaller {
  let homeDirectoryURL: URL
  let fileManager: FileManager

  init(
    homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
    fileManager: FileManager = .default,
  ) {
    self.homeDirectoryURL = homeDirectoryURL
    self.fileManager = fileManager
  }

  /// Install state for the unified hook map. See
  /// `ClaudeSettingsInstaller.installState()` for rationale.
  func installState() -> ComponentInstallState {
    let entries = KimiHookSettings.canonicalEntries()
    return fileInstaller.installState(
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
    Self.settingsURL(homeDirectoryURL: homeDirectoryURL)
  }

  static func settingsURL(homeDirectoryURL: URL) -> URL {
    homeDirectoryURL
      .appendingPathComponent(".kimi", isDirectory: true)
      .appendingPathComponent("config.toml", isDirectory: false)
  }

  private var fileInstaller: KimiHookSettingsFileInstaller {
    KimiHookSettingsFileInstaller(fileManager: fileManager)
  }
}
