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
    guard let contents = try? String(contentsOf: indexURL, encoding: .utf8) else {
      return false
    }
    return contents.contains(PiExtensionContent.ownershipMarker)
  }

  // MARK: - Install.

  func install() throws {
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
    // Only remove if this is our managed extension.
    let indexPath = extensionIndexURL.path(percentEncoded: false)
    if fileManager.fileExists(atPath: indexPath),
      let contents = try? String(contentsOf: extensionIndexURL, encoding: .utf8),
      contents.contains(PiExtensionContent.ownershipMarker)
    {
      try fileManager.removeItem(atPath: dirPath)
      piInstallerLogger.info("Uninstalled Pi extension from \(dirPath)")
    } else {
      piInstallerLogger.warning(
        "Skipped uninstall — extension at \(dirPath) is not Supacode-managed")
    }
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
