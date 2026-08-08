import Foundation
import GhosttyKit
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

  /// Everything needed to construct one surface, resolved ahead of the view.
  struct SurfacePlan {
    var command: String?
    var initialInput: String?
    var commandWrapper: [String]
    var environment: [String: String]
    var workingDirectory: URL?
    var fontSize: Float32?
    var context: ghostty_surface_context_e
  }

  /// Resolves the full construction plan for a layout-managed surface from the
  /// request's identity and its terminal payload.
  @MainActor
  static func plan(
    for request: ContentRequest,
    terminalState: TerminalContentState,
    worktree: Worktree,
    socketPath: String?,
    zmxExecutablePath: String?
  ) -> SurfacePlan {
    let launch = launch(
      LaunchIntent(),
      for: worktree,
      surfaceID: request.contentID.rawValue,
      zmxExecutablePath: zmxExecutablePath
    )
    // Remote worktrees have no local working directory: the surface command is
    // an `ssh` line and the cwd lives on the remote.
    let workingDirectory: URL? =
      worktree.host == nil
      ? terminalState.workingDirectory.map { URL(filePath: $0, directoryHint: .isDirectory) }
        ?? worktree.workingDirectory
      : nil
    return SurfacePlan(
      command: launch.command,
      initialInput: launch.initialInput,
      commandWrapper: launch.commandWrapper,
      environment: environment(
        for: worktree,
        tabID: request.tabID,
        surfaceID: request.contentID.rawValue,
        socketPath: socketPath
      ),
      workingDirectory: workingDirectory,
      // A woken surface keeps its frozen font: the frozen backing size only
      // reproduces the grid when the font, and so the cell size, matches.
      fontSize: terminalState.frozenGrid?.fontSize,
      context: context(for: request.origin)
    )
  }

  private static func context(for origin: ContentOrigin) -> ghostty_surface_context_e {
    switch origin {
    case .first:
      GHOSTTY_SURFACE_CONTEXT_WINDOW
    case .tab, .restored:
      GHOSTTY_SURFACE_CONTEXT_TAB
    case .split:
      GHOSTTY_SURFACE_CONTEXT_SPLIT
    }
  }
}

/// Live factory assembly: builds `TerminalContent` whose surface is created
/// lazily from a freshly resolved plan at the geometry the runtime provides.
@MainActor
struct TerminalContentBuilder {
  var runtime: GhosttyRuntime
  var worktree: (Worktree.ID) -> Worktree?
  var socketPath: () -> String?
  var zmxExecutablePath: () -> String?

  func factory() -> LayoutContentFactory {
    LayoutContentFactory { request in
      switch request.content {
      case .terminal(let terminalState):
        terminalContent(request, terminalState: terminalState)
      }
    }
  }

  private func terminalContent(
    _ request: ContentRequest,
    terminalState: TerminalContentState
  ) -> any TabContent {
    guard let worktree = worktree(request.worktreeID) else {
      // A vanished worktree cannot host a session; inert content keeps the
      // layout itself usable.
      TerminalSurfaceRecipe.builderLogger.error(
        "No worktree \(request.worktreeID.rawValue) for content \(request.contentID.rawValue)")
      return InertTabContent(id: request.contentID, state: request.content)
    }
    return TerminalContent(
      id: request.contentID,
      makeSurface: { geometry in
        let plan = TerminalSurfaceRecipe.plan(
          for: request,
          terminalState: terminalState,
          worktree: worktree,
          socketPath: socketPath(),
          zmxExecutablePath: zmxExecutablePath()
        )
        return GhosttySurfaceView(
          id: request.contentID.rawValue,
          runtime: runtime,
          workingDirectory: plan.workingDirectory,
          command: plan.command,
          initialInput: plan.initialInput,
          environmentVariables: plan.environment,
          commandWrapper: plan.commandWrapper,
          disableShellIntegration: false,
          fontSize: plan.fontSize,
          initialGeometry: geometry,
          context: plan.context
        )
      },
      initialState: terminalState
    )
  }
}

nonisolated extension TerminalSurfaceRecipe {
  fileprivate static let builderLogger = SupaLogger("TerminalContentBuilder")
}
