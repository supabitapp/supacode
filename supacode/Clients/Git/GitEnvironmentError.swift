import Foundation
import SupacodeSettingsShared

/// An environment-level git failure: the `git` binary itself is blocked or
/// unavailable, independent of any repository's health. Detected so repo status
/// checks can surface one actionable banner instead of marking every repo broken.
nonisolated enum GitEnvironmentError: Equatable, Sendable {
  /// `git` is gated behind an unaccepted Xcode license (`sudo xcodebuild -license`).
  case xcodeLicenseNotAccepted
  /// The active developer directory is missing or invalid (Xcode / command line
  /// tools not installed or not selected).
  case developerToolsUnavailable

  /// Classify a thrown git error as an environment-level failure, or `nil` if it's
  /// repository-specific. Keys on the diagnostic text (stdout + stderr), not the
  /// exit code, which the `wt` shim masks (it forwards git's stderr but exits 1
  /// via `die`).
  init?(classifying error: Error) {
    let text = Self.diagnosticText(from: error).lowercased()
    // Match the `xcodebuild -license` remedy git prints for the license gate,
    // plus the "agreed to the Xcode license" phrasing variants that omit it.
    if text.contains("xcodebuild -license") || text.contains("agreed to the xcode") {
      self = .xcodeLicenseNotAccepted
      return
    }
    if text.contains("invalid active developer path")
      || text.contains("xcode-select: error")
      || text.contains("requires xcode")
      || text.contains("no developer tools were found")
    {
      self = .developerToolsUnavailable
      return
    }
    return nil
  }

  private static func diagnosticText(from error: Error) -> String {
    if let shellError = error as? ShellClientError {
      return shellError.stdout + "\n" + shellError.stderr
    }
    if let gitError = error as? GitClientError, case .commandFailed(_, let message) = gitError {
      return message
    }
    return error.localizedDescription
  }
}

extension GitEnvironmentError {
  var title: String {
    switch self {
    case .xcodeLicenseNotAccepted:
      "Xcode license not accepted"
    case .developerToolsUnavailable:
      "Xcode command line tools required"
    }
  }

  var message: String {
    switch self {
    case .xcodeLicenseNotAccepted:
      "Supacode relies on git, which macOS blocks until you accept the Xcode license. "
        + "Run the command below in Terminal, then relaunch Supacode."
    case .developerToolsUnavailable:
      "Supacode relies on git, which needs Xcode's command line tools. "
        + "Run the command below in Terminal, then relaunch Supacode."
    }
  }

  /// Command the user runs in Terminal to clear the gate.
  var remedyCommand: String {
    switch self {
    case .xcodeLicenseNotAccepted:
      "sudo xcodebuild -license accept"
    case .developerToolsUnavailable:
      "xcode-select --install"
    }
  }
}
