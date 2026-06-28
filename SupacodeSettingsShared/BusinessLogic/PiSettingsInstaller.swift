import Foundation

private nonisolated let piInstallerLogger = SupaLogger("Settings")

nonisolated struct PiSettingsInstaller {
  let agent: SkillAgent
  let homeDirectoryURL: URL
  let fileManager: FileManager
  /// Optional binary-availability probe. nil for pi (pure file-write install);
  /// omp injects a real probe so install fails with `.ompUnavailable` when the
  /// `omp` binary is absent. Injectable for deterministic tests.
  let binaryProbe: (@Sendable () async throws -> Bool)?

  init(
    agent: SkillAgent = .pi,
    homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
    fileManager: FileManager = .default,
    binaryProbe: (@Sendable () async throws -> Bool)? = nil
  ) {
    self.agent = agent
    self.homeDirectoryURL = homeDirectoryURL
    self.fileManager = fileManager
    self.binaryProbe = binaryProbe
  }

  // MARK: - Check.

  func installState() -> ComponentInstallState {
    let indexURL = extensionIndexURL
    guard fileManager.fileExists(atPath: indexURL.path(percentEncoded: false)) else {
      return .notInstalled
    }
    // Surface read failures (permissions, non-UTF8 contents) instead of
    // conflating them with "not installed" — the UI would otherwise offer
    // Install and fail only on the next write.
    do {
      let contents = try String(contentsOf: indexURL, encoding: .utf8)
      guard contents.contains(PiExtensionContent.ownershipMarker) else {
        return .notInstalled
      }
      // Marker present but content drift = older Supacode wrote this file;
      // surface as outdated so the user gets an Update affordance.
      return contents == PiExtensionContent.indexTs(for: agent) ? .installed : .outdated
    } catch {
      piInstallerLogger.warning(
        "Pi extension at \(indexURL.path(percentEncoded: false)) is unreadable: \(error)")
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
    try PiExtensionContent.indexTs(for: agent).write(
      to: extensionIndexURL,
      atomically: true,
      encoding: .utf8
    )
    piInstallerLogger.info("Installed Pi extension at \(extensionIndexURL.path(percentEncoded: false))")
  }

  // MARK: - Availability.

  /// Throws `.ompUnavailable` when a probe is configured and reports the binary
  /// missing. No-op when `binaryProbe == nil`.
  func ensureBinaryAvailable() async throws {
    guard let binaryProbe else { return }
    guard try await binaryProbe() else {
      throw PiSettingsInstallerError.ompUnavailable
    }
  }

  /// Real omp availability probe: `command -v omp` through the login shell.
  /// Returns whether the binary resolves (exit 0). Mirrors
  /// `CodexSettingsInstaller.runEnableHooksCommand()` and reuses its
  /// `loginShellURL()`.
  static let ompBinaryProbe: @Sendable () async throws -> Bool = {
    let process = Process()
    process.executableURL = CodexSettingsInstaller.loginShellURL()
    process.arguments = ["-l", "-c", "command -v omp"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let status: Int32 = try await withCheckedThrowingContinuation { continuation in
      process.terminationHandler = { process in
        continuation.resume(returning: process.terminationStatus)
      }
      do {
        try process.run()
      } catch {
        continuation.resume(throwing: error)
      }
    }
    return status == 0
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
    Self.extensionDirectoryURL(homeDirectoryURL: homeDirectoryURL, agent: agent)
  }

  private var extensionIndexURL: URL {
    extensionDirectoryURL.appending(path: "index.ts", directoryHint: .notDirectory)
  }

  static func extensionDirectoryURL(homeDirectoryURL: URL, agent: SkillAgent = .pi) -> URL {
    homeDirectoryURL
      .appending(path: "\(agent.configDirectoryName)/extensions", directoryHint: .isDirectory)
      .appending(path: PiExtensionContent.extensionDirectoryName, directoryHint: .isDirectory)
  }
}

nonisolated enum PiSettingsInstallerError: Error, Equatable, LocalizedError {
  case extensionNotManaged
  case ompUnavailable

  var errorDescription: String? {
    switch self {
    case .extensionNotManaged:
      "The Pi extension at ~/.pi/agent/extensions/supacode is not managed by Supacode."
    case .ompUnavailable:
      "Oh My Pi (omp) must be installed and available in your login shell. Get it at https://omp.sh"
    }
  }
}
