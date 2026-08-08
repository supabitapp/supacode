import Foundation

private nonisolated let copilotInstallerLogger = SupaLogger("Settings")

/// Writes / removes Supacode's own `~/.copilot/hooks/supacode.json`. The hooks
/// dir is shared with the user's files, so only `supacode.json` is ever touched.
nonisolated struct CopilotHooksInstaller {
  let homeDirectoryURL: URL
  let fileManager: FileManager

  init(
    homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
    fileManager: FileManager = .default
  ) {
    self.homeDirectoryURL = homeDirectoryURL
    self.fileManager = fileManager
  }

  /// Marker present but content differs → `.outdated`; no marker → `.notInstalled`
  /// (so auto-update never overwrites a user file that shares the name).
  func installState() throws -> ComponentInstallState {
    guard let contents = try AgentFileProbe.text(at: hookFileURL) else { return .notInstalled }
    // Let a broken bundle throw rather than silently downgrading a correct
    // install to `.outdated`, which the auto-update would then act on.
    if contents == (try CopilotHookSettings.source()) { return .installed }
    return contents.contains(CopilotHookSettings.ownershipMarker) ? .outdated : .notInstalled
  }

  func install() throws {
    let path = hookFileURL.path(percentEncoded: false)
    // Read through the probe: a swallowed read error would read as "no marker
    // present" and let the unattended auto-update clobber a user's own file.
    if let contents = try AgentFileProbe.text(at: hookFileURL) {
      guard contents.contains(CopilotHookSettings.ownershipMarker) else {
        throw CopilotHooksInstallerError.fileNotManaged
      }
    }
    try fileManager.createDirectory(at: hooksDirectoryURL, withIntermediateDirectories: true)
    try CopilotHookSettings.source().write(to: hookFileURL, atomically: true, encoding: .utf8)
    copilotInstallerLogger.info("Installed Copilot hooks at \(path)")
  }

  func uninstall() throws {
    let path = hookFileURL.path(percentEncoded: false)
    // Never remove a user file that merely shares the name.
    guard let contents = try AgentFileProbe.text(at: hookFileURL) else { return }
    guard contents.contains(CopilotHookSettings.ownershipMarker) else {
      throw CopilotHooksInstallerError.fileNotManaged
    }
    try fileManager.removeItem(at: hookFileURL)
    copilotInstallerLogger.info("Uninstalled Copilot hooks from \(path)")
  }

  var hookFileURL: URL {
    hooksDirectoryURL.appending(path: CopilotHookSettings.fileName, directoryHint: .notDirectory)
  }

  private var hooksDirectoryURL: URL {
    Self.hooksDirectoryURL(homeDirectoryURL: homeDirectoryURL)
  }

  static func hooksDirectoryURL(homeDirectoryURL: URL) -> URL {
    homeDirectoryURL
      .appending(path: ".copilot", directoryHint: .isDirectory)
      .appending(path: "hooks", directoryHint: .isDirectory)
  }
}

nonisolated enum CopilotHooksInstallerError: Error, Equatable, LocalizedError {
  case fileNotManaged
  case encodingFailed

  var errorDescription: String? {
    switch self {
    case .fileNotManaged:
      "The Copilot hook file at ~/.copilot/hooks/supacode.json is not managed by Supacode."
    case .encodingFailed:
      "Failed to encode the Copilot hook payload."
    }
  }
}
