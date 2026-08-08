import Foundation

/// Installs (and removes) the Supacode presence plugin for OpenCode.
///
/// Unlike the Claude/Kiro JSON-merge installers, OpenCode loads plugins as
/// files from `~/.config/opencode/plugins/`, so this mirrors `CLISkillInstaller`
/// (write / remove a single owned file) rather than `ClaudeSettingsInstaller`
/// (prune-append into a shared JSON object). There is no foreign config to
/// preserve and no schema to satisfy.
nonisolated enum OpenCodePluginInstallerError: Error {
  case pluginNotManaged
}

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
  /// symmetric with `uninstall`. That alone does not stop an unattended
  /// overwrite (the aggregate can still be `.outdated` via another component),
  /// so `install` also refuses to clobber an unowned file.
  func installState() throws -> ComponentInstallState {
    guard let contents = try AgentFileProbe.text(at: pluginFileURL) else { return .notInstalled }
    if contents == OpenCodePluginContent.source() { return .installed }
    return contents.contains(OpenCodePluginContent.ownershipMarker) ? .outdated : .notInstalled
  }

  func install() throws {
    // Refuse to clobber a plugin Supacode doesn't own: auto-update calls this
    // unattended when the aggregate integration goes `.outdated`, which the
    // per-component `.notInstalled` alone does not prevent. Reading through the
    // probe means an unreadable file aborts rather than reading as "no marker".
    if let contents = try AgentFileProbe.text(at: pluginFileURL),
      !contents.contains(OpenCodePluginContent.ownershipMarker)
    {
      throw OpenCodePluginInstallerError.pluginNotManaged
    }
    try fileManager.createDirectory(at: pluginDirectoryURL, withIntermediateDirectories: true)
    try OpenCodePluginContent.source().write(to: pluginFileURL, atomically: true, encoding: .utf8)
  }

  func uninstall() throws {
    // Only remove a file Supacode owns — never clobber a user plugin that
    // happens to share the name. An unreadable plugin throws instead of
    // reporting a removal that never happened.
    guard let contents = try AgentFileProbe.text(at: pluginFileURL) else { return }
    guard contents.contains(OpenCodePluginContent.ownershipMarker) else { return }
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
