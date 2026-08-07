import Foundation
import Sharing
import SupacodeSettingsShared

/// Launch command and environment for a terminal surface, shared by the
/// legacy per-tab path and the layout content factory.
nonisolated enum TerminalSurfaceRecipe {
  private static let logger = SupaLogger("TerminalSurfaceRecipe")

  struct Launch: Equatable, Sendable {
    var command: String?
    var initialInput: String?
    var commandWrapper: [String]
    var usesZmx: Bool
  }

  /// What the caller wants the surface to run.
  struct LaunchIntent: Equatable, Sendable {
    var command: String?
    var initialInput: String?
    /// Blocking-script runners bypass zmx and keep their command verbatim.
    var bypassZmx = false
  }

  /// Resolves how a surface launches: verbatim for zmx bypass, an SSH
  /// reconnect loop for remote worktrees, a local zmx attach otherwise.
  @MainActor
  static func launch(
    _ intent: LaunchIntent,
    for worktree: Worktree,
    surfaceID: UUID,
    zmxExecutablePath: String?
  ) -> Launch {
    let command = intent.command
    let initialInput = intent.initialInput
    if intent.bypassZmx {
      return Launch(command: command, initialInput: initialInput, commandWrapper: [], usesZmx: false)
    }
    // Remote worktree: a *local* zmx session wraps a reconnect loop around the
    // SSH connection, and the remote reattaches its own zmx session when the
    // host has zmx (host persistence). The surface command is always the
    // reconnect-loop script (no command-wrapper, since Ghostty wraps the
    // local argv, not the loop). When the caller has no explicit command,
    // default to cd-into-the-remote-dir so a freshly created session lands in
    // the project.
    if let host = worktree.host {
      @Shared(.settingsFile) var settingsFile
      let remote = ZmxAttach.RemoteSurfaceLaunch(
        host: host,
        surfaceID: surfaceID,
        userCommand: command,
        defaultCommand: remoteDefaultShellCommand(
          remotePath: worktree.workingDirectory.path(percentEncoded: false)),
        hostPersistenceEnabled: settingsFile.global.remoteSessionPersistenceEnabled,
      )
      return Launch(
        command: ZmxAttach.buildRemoteCommand(remote, localZmxExecutablePath: zmxExecutablePath),
        initialInput: initialInput,
        commandWrapper: [],
        usesZmx: zmxExecutablePath != nil,
      )
    }
    let resolved = ZmxAttach.resolveLaunch(
      executablePath: zmxExecutablePath,
      sessionID: ZmxSessionID.make(surfaceID: surfaceID),
      command: command,
    )
    return Launch(
      command: resolved.command,
      initialInput: initialInput,
      commandWrapper: resolved.commandWrapper,
      usesZmx: zmxExecutablePath != nil,
    )
  }

  /// Connect default and reconnect fallback for a remote surface: `cd` into
  /// the remote project dir, then exec a login shell. The `cd` failure is
  /// swallowed so a stale path still drops the user into a usable shell. Nil
  /// for an empty/root path falls back to a bare login shell. The path is
  /// quoted for whichever login shell re-parses the session command.
  static func remoteDefaultShellCommand(remotePath: String) -> String? {
    let trimmed = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != "/" else { return nil }
    let quoted = SSHCommand.loginShellQuote(trimmed)
    return "cd \(quoted) 2>/dev/null; exec \"$SHELL\" -l"
  }

  /// Environment a surface starts with: the worktree's script variables,
  /// Supacode identity markers, caller extras, the zmx socket directory lock,
  /// and the bundled CLI on PATH.
  @MainActor
  static func environment(
    for worktree: Worktree,
    tabID: TerminalTabID,
    surfaceID: UUID,
    socketPath: String?,
    extraVariables: [String: String] = [:]
  ) -> [String: String] {
    var env = worktree.scriptEnvironment
    let percentEncodingSet = CharacterSet.urlPathAllowed.subtracting(.init(charactersIn: "/"))
    let repoPath = worktree.repositoryRootURL.path(percentEncoded: false)
    env["SUPACODE_REPO_ID"] = percentEncode(repoPath, allowedCharacters: percentEncodingSet, label: "SUPACODE_REPO_ID")
    env["SUPACODE_WORKTREE_ID"] = percentEncode(
      worktree.id.rawValue, allowedCharacters: percentEncodingSet, label: "SUPACODE_WORKTREE_ID")
    env["SUPACODE_TAB_ID"] = tabID.rawValue.uuidString
    env["SUPACODE_SURFACE_ID"] = surfaceID.uuidString
    if let socketPath {
      env["SUPACODE_SOCKET_PATH"] = socketPath
    }
    env.merge(extraVariables) { _, new in new }
    // Lock ZMX_DIR to the value the app's probe used so the shell can't
    // re-export a different value from .zshrc / .zprofile and silently
    // overflow `sockaddr_un.sun_path` past the probe's check.
    env["ZMX_DIR"] = ZmxSocketBudget.socketDir()
    // Prepend the bundled CLI binary directory to PATH so that `supacode`
    // resolves to the CLI tool, not the app binary added by Ghostty.
    if let cliBinDir = Bundle.main.resourceURL?
      .appending(path: "bin", directoryHint: .isDirectory)
      .path(percentEncoded: false)
    {
      let currentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
      env["PATH"] = currentPath.isEmpty ? cliBinDir : "\(cliBinDir):\(currentPath)"
    }
    return env
  }

  private static func percentEncode(
    _ value: String,
    allowedCharacters: CharacterSet,
    label: String
  ) -> String {
    guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowedCharacters) else {
      logger.warning(
        "Failed to percent-encode \(label): \(value). Downstream deeplinks using this value may be malformed.")
      return value
    }
    return encoded
  }
}
