import Foundation

/// Installs (and removes) the Supacode presence plugins for OpenCode.
///
/// Unlike the Claude/Kiro JSON-merge installers, OpenCode loads plugins as
/// files from `~/.config/opencode/plugins/`, so this mirrors `CLISkillInstaller`
/// (write / remove owned files) rather than `ClaudeSettingsInstaller`
/// (prune-append into a shared JSON object). There is no foreign config to
/// preserve and no schema to satisfy. Two entrypoints cover both OpenCode
/// generations: the 1.x server plugin and the 2.x TUI plugin.
nonisolated enum OpenCodePluginInstallerError: Error {
  case pluginNotManaged
}

nonisolated struct OpenCodePluginInstaller {
  let configDirectoryURL: URL
  let fileManager: FileManager

  init(
    homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
    configDirectoryURL: URL? = nil,
    fileManager: FileManager = .default
  ) {
    self.configDirectoryURL =
      configDirectoryURL ?? homeDirectoryURL.appending(path: ".config/opencode", directoryHint: .isDirectory)
    self.fileManager = fileManager
  }

  /// `.installed` only when every entrypoint matches byte-for-byte, so an older
  /// Supacode version's plugin (including the 1.x-only single file) reports
  /// `.outdated` and the next install upgrades it in place. Files Supacode does
  /// NOT own (no ownership marker) report `.notInstalled`, symmetric with
  /// `uninstall`. That alone does not stop an unattended overwrite (the aggregate
  /// can still be `.outdated` via another component), so `install` also refuses
  /// to clobber an unowned file.
  func installState() throws -> ComponentInstallState {
    let contents = try entrypoints.map { try AgentFileProbe.text(at: $0.url) }
    if contents == entrypoints.map(\.source) { return .installed }
    return contents.contains { $0?.contains(OpenCodePluginContent.ownershipMarker) == true }
      ? .outdated : .notInstalled
  }

  func install() throws {
    // Refuse to clobber a plugin Supacode doesn't own: auto-update calls this
    // unattended when the aggregate integration goes `.outdated`, which the
    // per-component `.notInstalled` alone does not prevent. Reading through the
    // probe means an unreadable file aborts rather than reading as "no marker".
    for entrypoint in entrypoints {
      if let contents = try AgentFileProbe.text(at: entrypoint.url),
        !contents.contains(OpenCodePluginContent.ownershipMarker)
      {
        throw OpenCodePluginInstallerError.pluginNotManaged
      }
    }
    for entrypoint in entrypoints {
      try fileManager.createDirectory(
        at: entrypoint.url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try entrypoint.source.write(to: entrypoint.url, atomically: true, encoding: .utf8)
    }
  }

  func uninstall() throws {
    // Only remove files Supacode owns — never clobber a user plugin that
    // happens to share the name. Every entrypoint is probed before anything is
    // removed, so an unreadable one throws instead of reporting a removal that
    // never happened.
    let owned = try entrypoints.filter {
      try AgentFileProbe.text(at: $0.url)?.contains(OpenCodePluginContent.ownershipMarker) == true
    }
    for entrypoint in owned {
      try fileManager.removeItem(at: entrypoint.url)
    }
    if (try? fileManager.contentsOfDirectory(atPath: tuiDirectoryURL.path))?.isEmpty == true {
      try fileManager.removeItem(at: tuiDirectoryURL)
    }
  }

  var serverPluginFileURL: URL {
    pluginsDirectoryURL.appending(path: OpenCodePluginContent.serverFileName, directoryHint: .notDirectory)
  }

  var tuiPluginFileURL: URL {
    tuiDirectoryURL.appending(path: OpenCodePluginContent.tuiFileName, directoryHint: .notDirectory)
  }

  private var entrypoints: [(url: URL, source: String)] {
    [
      (serverPluginFileURL, OpenCodePluginContent.serverSource()),
      (tuiPluginFileURL, OpenCodePluginContent.tuiSource()),
    ]
  }

  private var tuiDirectoryURL: URL {
    pluginsDirectoryURL.appending(path: OpenCodePluginContent.tuiDirectoryName, directoryHint: .isDirectory)
  }

  private var pluginsDirectoryURL: URL {
    configDirectoryURL.appending(path: "plugins", directoryHint: .isDirectory)
  }
}
