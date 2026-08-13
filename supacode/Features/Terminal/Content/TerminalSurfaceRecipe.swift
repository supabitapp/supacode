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
    tabID: TabID,
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
    /// Blocking-script runners emit their own OSC 133/7 and must not get
    /// Ghostty's shell integration injected into the host shell.
    var disableShellIntegration = false
    /// True when the session lives in zmx and survives renderer teardown.
    var usesZmx = false
  }

  /// Everything a surface plan resolves against beyond the request itself.
  @MainActor
  struct PlanSeed {
    var terminalState: TerminalContentState
    var worktree: Worktree
    var socketPath: String?
    var zmxExecutablePath: String?
    /// Live source surface for Ghostty's window-inherit config; nil spawns
    /// without inheritance.
    var inheritedFrom: GhosttySurfaceView?
    /// Font for a sourceless fresh spawn (the remembered zoom), pre-gated by
    /// the caller.
    var fallbackFontSize: Float32?
    /// Caller extras merged into the surface environment (script markers).
    var extraEnvironment: [String: String]

    init(
      terminalState: TerminalContentState,
      worktree: Worktree,
      socketPath: String?,
      zmxExecutablePath: String?,
      inheritedFrom: GhosttySurfaceView? = nil,
      fallbackFontSize: Float32? = nil,
      extraEnvironment: [String: String] = [:]
    ) {
      self.terminalState = terminalState
      self.worktree = worktree
      self.socketPath = socketPath
      self.zmxExecutablePath = zmxExecutablePath
      self.inheritedFrom = inheritedFrom
      self.fallbackFontSize = fallbackFontSize
      self.extraEnvironment = extraEnvironment
    }
  }

  /// Resolves the full construction plan for a layout-managed surface from the
  /// request's identity and its terminal payload.
  @MainActor
  static func plan(for request: ContentRequest, seed: PlanSeed) -> SurfacePlan {
    let override = seed.terminalState.launch
    let launch = launch(
      LaunchIntent(
        command: override?.command,
        initialInput: override?.initialInput,
        bypassZmx: override?.bypassZmx ?? false
      ),
      for: seed.worktree,
      surfaceID: request.contentID.rawValue,
      zmxExecutablePath: seed.zmxExecutablePath
    )
    let context = context(for: request.origin)
    let inherited = inheritedConfig(from: seed.inheritedFrom, context: context)
    // Remote worktrees have no local working directory: the surface command is
    // an `ssh` line and the cwd lives on the remote.
    let workingDirectory: URL? =
      seed.worktree.host == nil
      ? seed.terminalState.workingDirectory.map { URL(filePath: $0, directoryHint: .isDirectory) }
        ?? inherited.workingDirectory
        ?? seed.worktree.workingDirectory
      : nil
    // A woken surface keeps its frozen font: the frozen backing size only
    // reproduces the grid when the font, and so the cell size, matches.
    let fontSize: Float32? =
      seed.terminalState.frozenGrid != nil
      ? seed.terminalState.frozenGrid?.fontSize
      : (inherited.fontSize ?? seed.fallbackFontSize)
    return SurfacePlan(
      command: launch.command,
      initialInput: launch.initialInput,
      commandWrapper: launch.commandWrapper,
      environment: environment(
        for: seed.worktree,
        tabID: request.tabID,
        surfaceID: request.contentID.rawValue,
        socketPath: seed.socketPath,
        extraVariables: seed.extraEnvironment
      ),
      workingDirectory: workingDirectory,
      fontSize: fontSize,
      context: context,
      disableShellIntegration: override?.bypassZmx ?? false,
      usesZmx: launch.usesZmx
    )
  }

  /// Working directory and font a new surface inherits from its source's live
  /// session, per Ghostty's window-inherit config.
  @MainActor
  static func inheritedConfig(
    from source: GhosttySurfaceView?,
    context: ghostty_surface_context_e
  ) -> (workingDirectory: URL?, fontSize: Float32?) {
    guard let surface = source?.surface else { return (nil, nil) }
    let inherited = ghostty_surface_inherited_config(surface, context)
    let fontSize = inherited.font_size == 0 ? nil : inherited.font_size
    let workingDirectory = inherited.working_directory.flatMap { pointer -> URL? in
      let path = String(cString: pointer)
      return path.isEmpty ? nil : URL(filePath: path, directoryHint: .isDirectory)
    }
    return (workingDirectory, fontSize)
  }

  static let rememberedZoomFontSizeKey = "terminalRememberedFontSize"

  /// Remembered zoom font for a sourceless spawn; the gate is the caller's
  /// `window-inherit-font-size` read.
  @MainActor
  static func rememberedZoomFontSize(gatedBy windowInheritsFontSize: Bool) -> Float32? {
    guard windowInheritsFontSize else { return nil }
    @Shared(.appStorage(rememberedZoomFontSizeKey)) var stored: Double = 0
    return stored > 0 ? Float32(stored) : nil
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
  /// Live renderer lookup for window-inherit config; the integration layer
  /// wires it to `ContentRuntime`. No silent default: forgetting it would
  /// no-op the whole inheritance path.
  var sourceSurface: (ContentID) -> GhosttySurfaceView?
  /// Wires a freshly built surface's callbacks (the conduit). No silent
  /// default: an unwired surface would be deaf to every request.
  var wireSurface: (GhosttySurfaceView, ContentRequest) -> Void
  /// Extra environment for a spawning surface (blocking-script markers).
  var environmentExtras: (ContentRequest) -> [String: String]

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
    guard let capturedWorktree = worktree(request.worktreeID) else {
      // A vanished worktree cannot host a session; inert content keeps the
      // layout itself usable.
      TerminalSurfaceRecipe.builderLogger.error(
        "No worktree \(request.worktreeID.rawValue) for content \(request.contentID.rawValue)")
      return InertTabContent(id: request.contentID, state: request.content)
    }
    let lookUpWorktree = worktree
    return TerminalContent(
      id: request.contentID,
      makeSurface: { geometry, currentState, phase in
        // Re-resolve so a wake long after creation sees the current worktree;
        // the captured value only covers one that vanished mid-flight.
        let worktree = lookUpWorktree(request.worktreeID) ?? capturedWorktree
        // One-shot inheritance: a re-wake must not re-read the source's
        // current cwd/font or its split context.
        var effective = request
        var seedState = currentState
        if phase == .rewake {
          effective.origin = .restored
          effective.inheritedFrom = nil
        }
        if effective.origin == .restored {
          // The first spawn already delivered the launch override; a reattach
          // (same instance re-wake OR a rebuilt content after an unexpected
          // close) must not replay the command or its initial input.
          seedState = TerminalContentState(
            workingDirectory: currentState.workingDirectory,
            agents: currentState.agents,
            frozenGrid: currentState.frozenGrid
          )
        }
        let plan = TerminalSurfaceRecipe.plan(
          for: effective,
          seed: TerminalSurfaceRecipe.PlanSeed(
            terminalState: seedState,
            worktree: worktree,
            socketPath: socketPath(),
            zmxExecutablePath: zmxExecutablePath(),
            inheritedFrom: effective.inheritedFrom.flatMap(sourceSurface),
            fallbackFontSize: TerminalSurfaceRecipe.rememberedZoomFontSize(
              gatedBy: runtime.windowInheritsFontSize()
            ),
            extraEnvironment: environmentExtras(effective)
          )
        )
        let view = GhosttySurfaceView(
          id: request.contentID.rawValue,
          runtime: runtime,
          workingDirectory: plan.workingDirectory,
          command: plan.command,
          initialInput: plan.initialInput,
          environmentVariables: plan.environment,
          commandWrapper: plan.commandWrapper,
          disableShellIntegration: plan.disableShellIntegration,
          fontSize: plan.fontSize,
          initialGeometry: geometry,
          context: plan.context
        )
        wireSurface(view, effective)
        return TerminalContent.SpawnedSurface(view: view, usesZmx: plan.usesZmx)
      },
      initialState: terminalState
    )
  }
}

nonisolated extension TerminalSurfaceRecipe {
  fileprivate static let builderLogger = SupaLogger("TerminalContentBuilder")
}
