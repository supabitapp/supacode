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

  func isInstalled() -> Bool {
    let indexURL = extensionIndexURL
    guard fileManager.fileExists(atPath: indexURL.path(percentEncoded: false)) else {
      return false
    }
    // Surface read failures (permissions, non-UTF8 contents) instead of
    // conflating them with "not installed" — the UI would otherwise offer
    // Install and fail only on the next write.
    do {
      let contents = try String(contentsOf: indexURL, encoding: .utf8)
      return contents.contains(PiExtensionContent.ownershipMarker)
    } catch {
      piInstallerLogger.warning(
        "Pi extension at \(indexURL.path(percentEncoded: false)) is unreadable: \(error)")
      return false
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
        piInstallerLogger.warning(
          "Pi install pre-check: unable to read \(indexPath): \(error)")
        throw error
      }
      guard contents.contains(PiExtensionContent.ownershipMarker) else {
        throw PiSettingsInstallerError.extensionNotManaged
      }
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
    let indexPath = extensionIndexURL.path(percentEncoded: false)
    guard fileManager.fileExists(atPath: indexPath) else {
      try fileManager.removeItem(atPath: dirPath)
      piInstallerLogger.info("Removed stale empty Pi extension directory at \(dirPath)")
      return
    }
    // Refuse to remove a user-authored extension at the managed path;
    // surface it as a typed error so the reducer can show `.failed(…)`
    // instead of silently flipping the UI to "not installed".
    let contents = try String(contentsOf: extensionIndexURL, encoding: .utf8)
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
