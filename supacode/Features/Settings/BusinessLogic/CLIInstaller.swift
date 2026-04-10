import Foundation

nonisolated struct CLIInstaller {
  private static let installPath = "/usr/local/bin/supacode"

  /// Returns the path to the CLI binary inside the app bundle.
  static var bundledCLIPath: String? {
    Bundle.main.resourceURL?
      .appending(path: "bin/supacode", directoryHint: .notDirectory)
      .path(percentEncoded: false)
  }

  func isInstalled() -> Bool {
    guard let bundledPath = Self.bundledCLIPath else { return false }
    guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: Self.installPath) else {
      return false
    }
    return dest == bundledPath
  }

  func install() throws {
    guard let bundledPath = Self.bundledCLIPath else {
      throw CLIInstallerError.bundledBinaryNotFound
    }
    guard FileManager.default.fileExists(atPath: bundledPath) else {
      throw CLIInstallerError.bundledBinaryNotFound
    }

    // Use NSAppleScript to create the symlink with admin privileges.
    let dir = shellEscape(
      URL(filePath: Self.installPath).deletingLastPathComponent().path(percentEncoded: false))
    let dst = shellEscape(Self.installPath)
    let src = shellEscape(bundledPath)
    try runPrivileged(
      "mkdir -p \(dir) && rm -f \(dst) && ln -s \(src) \(dst)",
      prompt: "Supacode needs administrator access to install the CLI to /usr/local/bin."
    )
  }

  func uninstall() throws {
    guard isInstalled() else { return }
    try runPrivileged(
      "rm -f \(shellEscape(Self.installPath))",
      prompt: "Supacode needs administrator access to uninstall the CLI from /usr/local/bin."
    )
  }

  /// Runs a shell command with administrator privileges via `NSAppleScript`.
  ///
  /// Using `NSAppleScript` in-process (instead of shelling out to `/usr/bin/osascript`)
  /// makes macOS show the Supacode icon and name in the authorization dialog.
  private func runPrivileged(_ command: String, prompt: String) throws {
    let escapedCommand = command.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"")
    let escapedPrompt = prompt.replacing("\"", with: "\\\"")
    let source =
      "do shell script \"\(escapedCommand)\" with prompt \"\(escapedPrompt)\" with administrator privileges"
    guard let script = NSAppleScript(source: source) else {
      throw CLIInstallerError.installFailed("Failed to prepare authorization script.")
    }
    var errorInfo: NSDictionary?
    script.executeAndReturnError(&errorInfo)
    guard errorInfo == nil else {
      let errorNumber = errorInfo?[NSAppleScript.errorNumber] as? Int
      // -128 means the user cancelled the authorization dialog.
      if errorNumber == -128 {
        throw CLIInstallerError.cancelled
      }
      let message = errorInfo?[NSAppleScript.errorMessage] as? String ?? ""
      throw CLIInstallerError.installFailed(message)
    }
  }
}

/// Wraps a value in single quotes, escaping embedded single quotes.
private nonisolated func shellEscape(_ value: String) -> String {
  "'" + value.replacing("'", with: "'\\''") + "'"
}

nonisolated enum CLIInstallerError: Error, LocalizedError, Equatable {
  case bundledBinaryNotFound
  case cancelled
  case installFailed(String)

  var errorDescription: String? {
    switch self {
    case .bundledBinaryNotFound:
      "The CLI binary was not found in the app bundle."
    case .cancelled:
      nil
    case .installFailed(let reason):
      reason.isEmpty ? "Installation failed." : reason
    }
  }
}
