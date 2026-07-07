import Foundation

private nonisolated let ompInstallerLogger = SupaLogger("Settings")

nonisolated struct OmpSettingsInstaller {
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

  func installState() -> ComponentInstallState {
    let indexURL = extensionIndexURL
    guard fileManager.fileExists(atPath: indexURL.path(percentEncoded: false)) else {
      return .notInstalled
    }
    // Treat an unreadable file (permissions, non-UTF8 contents) as not-installed
    // but log it, so a permission or encoding fault stays diagnosable. The next
    // Install attempt rethrows the real read error to the reducer.
    do {
      let contents = try String(contentsOf: indexURL, encoding: .utf8)
      guard contents.contains(OmpExtensionContent.ownershipMarker) else {
        return .notInstalled
      }
      // Marker present but content drift = older Supacode wrote this file;
      // surface as outdated so the user gets an Update affordance.
      return contents == OmpExtensionContent.indexTs ? .installed : .outdated
    } catch {
      ompInstallerLogger.warning(
        "OMP extension at \(indexURL.path(percentEncoded: false)) is unreadable: \(error)")
      return .notInstalled
    }
  }

  // MARK: - Install.

  func install() throws {
    // Refuse to clobber a user-authored extension at the managed path so
    // Install is symmetric with Uninstall's ownership guard.
    let indexPath = extensionIndexURL.path(percentEncoded: false)
    if fileManager.fileExists(atPath: indexPath) {
      let contents: String
      do {
        contents = try String(contentsOf: extensionIndexURL, encoding: .utf8)
      } catch {
        // Surface the path so the reducer's generic localizedDescription
        // alone does not lose the file we were trying to probe.
        ompInstallerLogger.warning(
          "OMP install pre-check: unable to read \(indexPath): \(error)")
        throw error
      }
      guard contents.contains(OmpExtensionContent.ownershipMarker) else {
        throw OmpSettingsInstallerError.extensionNotManaged
      }
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
    let indexPath = extensionIndexURL.path(percentEncoded: false)
    guard fileManager.fileExists(atPath: indexPath) else {
      try fileManager.removeItem(atPath: dirPath)
      ompInstallerLogger.info("Removed stale empty OMP extension directory at \(dirPath)")
      return
    }
    // Refuse to remove a user-authored extension at the managed path;
    // surface it as a typed error so the reducer can show `.failed(…)`
    // instead of silently flipping the UI to "not installed".
    let contents = try String(contentsOf: extensionIndexURL, encoding: .utf8)
    guard contents.contains(OmpExtensionContent.ownershipMarker) else {
      throw OmpSettingsInstallerError.extensionNotManaged
    }
    try fileManager.removeItem(atPath: dirPath)
    ompInstallerLogger.info("Uninstalled OMP extension from \(dirPath)")
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
      .appending(path: ".omp/agent/extensions", directoryHint: .isDirectory)
      .appending(path: OmpExtensionContent.extensionDirectoryName, directoryHint: .isDirectory)
  }
}

nonisolated enum OmpSettingsInstallerError: Error, Equatable, LocalizedError {
  case extensionNotManaged

  var errorDescription: String? {
    switch self {
    case .extensionNotManaged:
      "The OMP extension at ~/.omp/agent/extensions/supacode is not managed by Supacode."
    }
  }
}
