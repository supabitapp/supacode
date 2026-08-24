import Foundation

private nonisolated let ompInstallerLogger = SupaLogger("Settings")

nonisolated struct OmpSettingsInstaller {
  let configDirectoryURL: URL
  let fileManager: FileManager

  init(
    homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
    configDirectoryURL: URL? = nil,
    fileManager: FileManager = .default
  ) {
    self.configDirectoryURL =
      configDirectoryURL ?? homeDirectoryURL.appending(path: ".omp/agent", directoryHint: .isDirectory)
    self.fileManager = fileManager
  }

  // MARK: - Check.

  /// Throws when the extension exists but can't be read: an unreadable file is
  /// not an absent one, and reporting absence hides the fault from the user.
  func installState() throws -> ComponentInstallState {
    guard let contents = try AgentFileProbe.text(at: extensionIndexURL) else { return .notInstalled }
    guard contents.contains(OmpExtensionContent.ownershipMarker) else { return .notInstalled }
    // Marker present but content drift = older Supacode wrote this file;
    // surface as outdated so the user gets an Update affordance.
    return contents == OmpExtensionContent.indexTs ? .installed : .outdated
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
      ompInstallerLogger.warning("OMP install pre-check: unable to read \(indexPath): \(error)")
      throw error
    }
    if let contents, !contents.contains(OmpExtensionContent.ownershipMarker) {
      throw OmpSettingsInstallerError.extensionNotManaged(
        path: (extensionDirectoryURL.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath)
    }
    let dirPath = extensionDirectoryURL.path(percentEncoded: false)
    try fileManager.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
    try OmpExtensionContent.indexTs.write(
      to: extensionIndexURL,
      atomically: true,
      encoding: .utf8
    )
    ompInstallerLogger.info("Installed OMP extension at \(extensionIndexURL.path(percentEncoded: false))")
  }

  // MARK: - Uninstall.

  func uninstall() throws {
    let dirPath = extensionDirectoryURL.path(percentEncoded: false)
    guard fileManager.fileExists(atPath: dirPath) else { return }
    // Probe rather than stat: a read that merely failed must not be mistaken
    // for an empty directory, which would delete whatever is really in there.
    guard let contents = try AgentFileProbe.text(at: extensionIndexURL) else {
      try fileManager.removeItem(atPath: dirPath)
      ompInstallerLogger.info("Removed stale empty OMP extension directory at \(dirPath)")
      return
    }
    // Refuse to remove a user-authored extension at the managed path;
    // surface it as a typed error so the reducer can show `.failed(…)`
    // instead of silently flipping the UI to "not installed".
    guard contents.contains(OmpExtensionContent.ownershipMarker) else {
      throw OmpSettingsInstallerError.extensionNotManaged(
        path: (extensionDirectoryURL.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath)
    }
    try fileManager.removeItem(atPath: dirPath)
    ompInstallerLogger.info("Uninstalled OMP extension from \(dirPath)")
  }

  // MARK: - Paths.

  private var extensionDirectoryURL: URL {
    configDirectoryURL
      .appending(path: "extensions", directoryHint: .isDirectory)
      .appending(path: OmpExtensionContent.extensionDirectoryName, directoryHint: .isDirectory)
  }

  private var extensionIndexURL: URL {
    extensionDirectoryURL.appending(path: "index.ts", directoryHint: .notDirectory)
  }

  static func extensionDirectoryURL(homeDirectoryURL: URL) -> URL {
    homeDirectoryURL
      .appending(path: ".omp/agent/extensions", directoryHint: .isDirectory)
      .appending(path: OmpExtensionContent.extensionDirectoryName, directoryHint: .isDirectory)
  }
}

nonisolated enum OmpSettingsInstallerError: Error, Equatable, LocalizedError {
  case extensionNotManaged(path: String)

  var errorDescription: String? {
    switch self {
    case .extensionNotManaged(let path):
      "The OMP extension at \(path) is not managed by Supacode."
    }
  }
}
