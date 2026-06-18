import Foundation

/// Installs (and removes) the Supacode presence plugin for OpenCode.
///
/// Unlike the Claude/Kiro JSON-merge installers, OpenCode loads plugins as
/// files from `~/.config/opencode/plugins/`, so this mirrors `CLISkillInstaller`
/// (write / remove a single owned file) rather than `ClaudeSettingsInstaller`
/// (prune-append into a shared JSON object). There is no foreign config to
/// preserve and no schema to satisfy.
nonisolated struct OpenCodePluginInstaller {
  let homeDirectoryURL: URL
  let fileManager: FileManager

  init(
    homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
    fileManager: FileManager = .default
  ) {
    self.homeDirectoryURL = homeDirectoryURL
    self.fileManager = fileManager
  }

  /// `.installed` only on a byte-for-byte match, so an older Supacode version's
  /// plugin reports `.outdated` and the next install upgrades it in place. A
  /// file Supacode does NOT own (no ownership marker) reports `.notInstalled`,
  /// not `.outdated`, so auto-update never silently overwrites a user plugin
  /// that happens to share the name — symmetric with `uninstall`.
  func installState() -> ComponentInstallState {
    guard let contents = try? String(contentsOf: pluginFileURL, encoding: .utf8) else {
      return .notInstalled
    }
    if contents == OpenCodePluginContent.source() { return .installed }
    return contents.contains(OpenCodePluginContent.ownershipMarker) ? .outdated : .notInstalled
  }

  func install() throws {
    try fileManager.createDirectory(at: pluginDirectoryURL, withIntermediateDirectories: true)
    try OpenCodePluginContent.source().write(to: pluginFileURL, atomically: true, encoding: .utf8)
  }

  func uninstall() throws {
    // Only remove a file Supacode owns — never clobber a user plugin that
    // happens to share the name.
    guard let contents = try? String(contentsOf: pluginFileURL, encoding: .utf8),
      contents.contains(OpenCodePluginContent.ownershipMarker)
    else {
      return
    }
    try fileManager.removeItem(at: pluginFileURL)
  }

  var pluginFileURL: URL {
    pluginDirectoryURL.appendingPathComponent(OpenCodePluginContent.pluginFileName, isDirectory: false)
  }

  private var pluginDirectoryURL: URL {
    Self.pluginDirectoryURL(homeDirectoryURL: homeDirectoryURL)
  }

  static func pluginDirectoryURL(homeDirectoryURL: URL) -> URL {
    homeDirectoryURL
      .appendingPathComponent(".config", isDirectory: true)
      .appendingPathComponent("opencode", isDirectory: true)
      .appendingPathComponent("plugins", isDirectory: true)
  }
}
