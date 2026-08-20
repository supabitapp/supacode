import Darwin
import Foundation
import SupacodeSettingsShared

nonisolated enum ForgeCLIResolutionError: Error, Equatable {
  case executableNotFound
}

/// Resolves a forge CLI executable: `which` in a non-login shell, then a login
/// shell, then fixed fallback paths. The result is cached; `invalidate()` after
/// ENOENT-class failures so a moved binary re-resolves.
actor ForgeCLIExecutableResolver {
  nonisolated private static let logger = SupaLogger("ForgeCLI")

  private let executableName: String
  private let fallbackExecutableURLs: [URL]
  private var cachedExecutableURL: URL?
  private var inFlightResolution: Task<URL, Error>?

  init(executableName: String, fallbackExecutableURLs: [URL]) {
    self.executableName = executableName
    self.fallbackExecutableURLs = fallbackExecutableURLs
  }

  func executableURL(shell: ShellClient) async throws -> URL {
    if let cachedExecutableURL {
      return cachedExecutableURL
    }
    if let inFlightResolution {
      return try await inFlightResolution.value
    }
    let resolutionTask = Task {
      try await resolveExecutableURL(shell: shell)
    }
    inFlightResolution = resolutionTask
    do {
      let executableURL = try await resolutionTask.value
      cachedExecutableURL = executableURL
      inFlightResolution = nil
      return executableURL
    } catch {
      inFlightResolution = nil
      throw error
    }
  }

  func invalidate() {
    cachedExecutableURL = nil
    inFlightResolution?.cancel()
    inFlightResolution = nil
  }

  private func resolveExecutableURL(shell: ShellClient) async throws -> URL {
    if let executableURL = await locateExecutableURL(shell: shell, useLoginShell: false) {
      return executableURL
    }
    if let executableURL = await locateExecutableURL(shell: shell, useLoginShell: true) {
      return executableURL
    }
    if let executableURL = fallbackExecutableURLs.first(where: {
      FileManager.default.isExecutableFile(atPath: $0.path)
    }) {
      // Shell PATH missed the CLI; note the fixed-path fallback so a mismatch with the user's terminal is traceable.
      Self.logger.info(
        "Resolved \(self.executableName) via fallback path \(executableURL.path); shell PATH resolution failed."
      )
      return executableURL
    }
    throw ForgeCLIResolutionError.executableNotFound
  }

  nonisolated static func defaultFallbackExecutableURLs(
    executableName: String,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> [URL] {
    [
      "/opt/homebrew/bin/\(executableName)",
      "/usr/local/bin/\(executableName)",
      environment["HOME"].map { "\($0)/.local/bin/\(executableName)" },
    ]
    .compactMap { $0 }
    .map { URL(fileURLWithPath: $0) }
  }

  private func locateExecutableURL(
    shell: ShellClient,
    useLoginShell: Bool
  ) async -> URL? {
    let whichURL = URL(fileURLWithPath: "/usr/bin/which")
    do {
      let output: String
      if useLoginShell {
        output = try await shell.runLogin(whichURL, [executableName], nil, log: false).stdout
      } else {
        output = try await shell.run(whichURL, [executableName], nil).stdout
      }
      let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else {
        return nil
      }
      return URL(fileURLWithPath: trimmed)
    } catch {
      return nil
    }
  }
}

extension ForgeCLIExecutableResolver {
  /// ENOENT-class failures mean the cached executable path went stale (moved,
  /// upgraded, uninstalled); resolve once more before giving up.
  nonisolated static func shouldRetryExecution(after error: Error) -> Bool {
    if let shellError = error as? ShellClientError {
      let combined = "\(shellError.stdout)\n\(shellError.stderr)".lowercased()
      if combined.contains("no such file or directory") || combined.contains("command not found") {
        return true
      }
      if shellError.exitCode == 127 {
        return true
      }
    }
    let nsError = error as NSError
    if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileNoSuchFileError {
      return true
    }
    if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT) {
      return true
    }
    return false
  }
}
