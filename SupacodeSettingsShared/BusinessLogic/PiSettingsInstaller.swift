import Foundation

private nonisolated let piInstallerLogger = SupaLogger("Settings")

nonisolated struct PiSettingsInstaller {
  let homeDirectoryURL: URL
  let fileManager: FileManager

  init(
    homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
    fileManager: FileManager = .default
  ) {
    self.homeDirectoryURL = homeDirectoryURL
    self.fileManager = fileManager
  }

  // MARK: - Check.

  /// Throws when the extension exists but can't be read: an unreadable file is
  /// not an absent one, and reporting absence hides the fault from the user.
  func installState() throws -> ComponentInstallState {
    guard let contents = try AgentFileProbe.text(at: extensionIndexURL) else { return .notInstalled }
    guard contents.contains(PiExtensionContent.ownershipMarker) else { return .notInstalled }
    // Marker present but content drift = older Supacode wrote this file;
    // surface as outdated so the user gets an Update affordance.
    return contents == PiExtensionContent.indexTs ? .installed : .outdated
  }

  // MARK: - Install.

  func install() throws {
    // Refuse to clobber a user-authored extension at the managed path so
    // Install is symmetric with Uninstall's ownership guard.
    let indexPath = extensionIndexURL.path(percentEncoded: false)
    let contents: String?
    do {
      contents = try AgentFileProbe.text(at: extensionIndexURL)
    } catch {
      // Surface the path so the reducer's generic localizedDescription
      // alone does not lose the file we were trying to probe.
      piInstallerLogger.warning("Pi install pre-check: unable to read \(indexPath): \(error)")
      throw error
    }
    if let contents, !contents.contains(PiExtensionContent.ownershipMarker) {
      throw PiSettingsInstallerError.extensionNotManaged
    }
    let dirPath = extensionDirectoryURL.path(percentEncoded: false)
    try fileManager.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
    try PiExtensionContent.indexTs.write(
      to: extensionIndexURL,
      atomically: true,
      encoding: .utf8
    )
    piInstallerLogger.info("Installed Pi extension at \(extensionIndexURL.path(percentEncoded: false))")
  }

  // MARK: - Uninstall.

  func uninstall() throws {
    let dirPath = extensionDirectoryURL.path(percentEncoded: false)
    guard fileManager.fileExists(atPath: dirPath) else { return }
    // Probe rather than stat: a read that merely failed must not be mistaken
    // for an empty directory, which would delete whatever is really in there.
    guard let contents = try AgentFileProbe.text(at: extensionIndexURL) else {
      try fileManager.removeItem(atPath: dirPath)
      piInstallerLogger.info("Removed stale empty Pi extension directory at \(dirPath)")
      return
    }
    // Refuse to remove a user-authored extension at the managed path;
    // surface it as a typed error so the reducer can show `.failed(…)`
    // instead of silently flipping the UI to "not installed".
    guard contents.contains(PiExtensionContent.ownershipMarker) else {
      throw PiSettingsInstallerError.extensionNotManaged
    }
    try fileManager.removeItem(atPath: dirPath)
    piInstallerLogger.info("Uninstalled Pi extension from \(dirPath)")
  }

  // MARK: - Paths.

  private var extensionDirectoryURL: URL {
    Self.extensionDirectoryURL(homeDirectoryURL: homeDirectoryURL)
  }

  private var extensionIndexURL: URL {
    extensionDirectoryURL.appending(path: "index.ts", directoryHint: .notDirectory)
  }

  static func extensionDirectoryURL(homeDirectoryURL: URL) -> URL {
    homeDirectoryURL
      .appending(path: ".pi/agent/extensions", directoryHint: .isDirectory)
      .appending(path: PiExtensionContent.extensionDirectoryName, directoryHint: .isDirectory)
  }
}

nonisolated enum PiSettingsInstallerError: Error, Equatable, LocalizedError {
  case extensionNotManaged

  var errorDescription: String? {
    switch self {
    case .extensionNotManaged:
      "The Pi extension at ~/.pi/agent/extensions/supacode is not managed by Supacode."
    }
  }
}
