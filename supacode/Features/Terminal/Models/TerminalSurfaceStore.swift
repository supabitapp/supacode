import AppKit
import Dependencies
import Foundation
import GhosttyKit
import Sharing
import SupacodeSettingsShared

private let blockingScriptLogger = SupaLogger("BlockingScript")
private let storeLogger = SupaLogger("Terminal")

/// Per-worktree store for terminal-kind state: the Ghostty view map, zmx
/// launch/session bookkeeping, blocking scripts, setup-script consumption,
/// working-dir/environment injection, and agent-OSC notification dedupe.
///
/// `WorktreeTerminalState`'s generic core (tree / tab / focus / occlusion /
/// zoom / persistence scheduling) reaches terminal-only state exclusively
/// through this store, so a future surface kind adds a sibling store instead
/// of new fields on the shared class. Everything here is keyed by surface or
/// tab ID and empty when no terminal surface exists, so absent kinds cost
/// nothing (no state multiplication).
@MainActor
@Observable
final class TerminalSurfaceStore {
  struct SurfaceLaunchMetadata {
    let usesZmx: Bool
    let context: ghostty_surface_context_e
  }

  struct ResolvedLaunch {
    var command: String?
    var initialInput: String?
    var commandWrapper: [String]
    var usesZmx: Bool
  }

  private let worktree: Worktree
  var socketPath: String?
  @ObservationIgnored
  @SharedReader private var repositorySettings: RepositorySettings
  @ObservationIgnored @Dependency(\.zmxClient) private var zmxClient
  @ObservationIgnored @Dependency(\.analyticsClient) private var analyticsClient

  @ObservationIgnored var surfaces: [UUID: GhosttySurfaceView] = [:]
  // `usesZmx` + `context` retained per surface so an unexpected zmx exit can recreate it on reattach.
  @ObservationIgnored var surfaceLaunchMetadata: [UUID: SurfaceLaunchMetadata] = [:]
  // Surfaces the user explicitly closed, so an unexpected zmx exit isn't mistaken for one and reattached.
  @ObservationIgnored var pendingExplicitSurfaceCloseIDs: Set<UUID> = []
  var blockingScripts: [TerminalTabID: BlockingScriptKind] = [:]
  var blockingScriptLaunchDirectories: [TerminalTabID: URL] = [:]
  var lastBlockingScriptTabByKind: [BlockingScriptKind: TerminalTabID] = [:]
  var pendingSetupScript: Bool
  /// When a custom (hook / OSC 3008) notification last committed per surface.
  /// Stored as a monotonic instant so the suppression window and the OSC-9 hold
  /// share one clock source and can't desync on an NTP step / manual clock change.
  var lastCustomNotificationAt: [UUID: any InstantProtocol<Duration>] = [:]
  /// Agent OSC 9 notifications held to see if a custom notification supersedes them.
  var pendingAgentOSCNotifications: [UUID: Task<Void, Never>] = [:]

  init(worktree: Worktree, pendingSetupScript: Bool) {
    self.worktree = worktree
    self.pendingSetupScript = pendingSetupScript
    _repositorySettings = SharedReader(
      wrappedValue: RepositorySettings.default,
      .repositorySettings(worktree.repositoryRootURL, host: worktree.host)
    )
  }

  func setupScriptInput(setupScript: String?) -> String? {
    guard pendingSetupScript, let script = setupScript else { return nil }
    return BlockingScriptRunner.makeCommandInput(script: script)
  }

  func cleanupBlockingScriptLaunchDirectory(for tabId: TerminalTabID) {
    guard let directoryURL = blockingScriptLaunchDirectories.removeValue(forKey: tabId) else { return }
    cleanupBlockingScriptLaunchDirectory(at: directoryURL)
  }

  func cleanupBlockingScriptLaunchDirectories() {
    let directoryURLs = blockingScriptLaunchDirectories.values
    blockingScriptLaunchDirectories.removeAll()
    for directoryURL in directoryURLs {
      cleanupBlockingScriptLaunchDirectory(at: directoryURL)
    }
  }

  func cleanupBlockingScriptLaunchDirectory(at directoryURL: URL) {
    do {
      try FileManager.default.removeItem(at: directoryURL)
    } catch {
      blockingScriptLogger.warning(
        "Failed to remove blocking script launch directory \(directoryURL.path(percentEncoded: false)): \(error)"
      )
    }
  }

  // The typed command stays shell-portable by invoking a generated wrapper file
  // that reads the shell path from a sibling file and launches the user script,
  // rather than serializing it into a shell-escaped `-c` string.
  func blockingScriptLaunch(_ script: String) throws -> BlockingScriptRunner.LaunchArtifacts? {
    try BlockingScriptRunner.makeLaunch(
      script: script,
      shellPath: defaultShellPath()
    )
  }

  func surfaceEnvironment(tabId: TerminalTabID, surfaceID: UUID) -> [String: String] {
    var env = worktree.scriptEnvironment
    let percentEncodingSet = CharacterSet.urlPathAllowed.subtracting(.init(charactersIn: "/"))
    let repoPath = worktree.repositoryRootURL.path(percentEncoded: false)
    env["SUPACODE_REPO_ID"] = percentEncode(repoPath, allowedCharacters: percentEncodingSet, label: "SUPACODE_REPO_ID")
    env["SUPACODE_WORKTREE_ID"] = percentEncode(
      worktree.id.rawValue, allowedCharacters: percentEncodingSet, label: "SUPACODE_WORKTREE_ID")
    env["SUPACODE_TAB_ID"] = tabId.rawValue.uuidString
    env["SUPACODE_SURFACE_ID"] = surfaceID.uuidString
    if let socketPath {
      env["SUPACODE_SOCKET_PATH"] = socketPath
    }
    // Mark blocking-script surfaces so the user's shell profile can skip its
    // interactive init (prompt, plugins, banners) for these transient tabs.
    if let blockingScriptKind = blockingScripts[tabId] {
      env.merge(blockingScriptEnvironment(for: blockingScriptKind)) { _, new in new }
    }
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

  /// Blocking-script marker env vars for a kind, with scope resolved against
  /// this worktree's settings. Shared by the local surface environment and the
  /// remote runner export so both hosts expose the same signal.
  func blockingScriptEnvironment(for kind: BlockingScriptKind) -> [String: String] {
    let scope = kind.scriptDefinitionID.flatMap(scriptScope(forDefinitionID:))
    return kind.surfaceEnvironmentVariables(scope: scope)
  }

  /// Resolves whether a user-defined script is repo- or global-owned, mirroring
  /// the repo-wins merge: an ID present in repo settings is `.repo`, otherwise
  /// `.global`. Returns `nil` for a script that resolves to neither (e.g. a
  /// since-deleted deeplink target).
  private func scriptScope(forDefinitionID id: UUID) -> ScriptScope? {
    if repositorySettings.scripts.contains(where: { $0.id == id }) { return .repo }
    @Shared(.settingsFile) var settingsFile
    if settingsFile.global.globalScripts.contains(where: { $0.id == id }) { return .global }
    return nil
  }

  private func percentEncode(_ value: String, allowedCharacters: CharacterSet, label: String) -> String {
    guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowedCharacters) else {
      storeLogger.warning(
        "Failed to percent-encode \(label): \(value). Downstream deeplinks using this value may be malformed.")
      return value
    }
    return encoded
  }

  /// Routes a surface through zmx so the underlying shell survives app quit.
  ///
  /// Interactive surfaces (no explicit `command`) keep `command` nil and inject
  /// `zmx attach <id>` as a Ghostty `command-wrapper`, so Ghostty resolves and
  /// integrates the user's real shell exactly as it would without zmx, with zmx
  /// wrapping the whole resolved (login + integrated) argv.
  ///
  /// Explicit commands (scripts) instead wrap the command string itself, since
  /// they don't want shell resolution / integration. `initialInput` is always
  /// passed through; zmx is authoritative for attach-vs-create.
  func resolveLaunch(
    surfaceID: UUID,
    command: String?,
    initialInput: String?,
    bypassZmx: Bool
  ) -> ResolvedLaunch {
    if bypassZmx {
      return ResolvedLaunch(command: command, initialInput: initialInput, commandWrapper: [], usesZmx: false)
    }
    let zmxExecutablePath = zmxClient.executableURL()?.path(percentEncoded: false)
    // Remote worktree: a *local* zmx session wraps a reconnect loop around the
    // SSH connection, and the remote reattaches its own zmx session when the
    // host has zmx (host persistence). The surface command is always the
    // reconnect-loop script (no command-wrapper, since Ghostty wraps the
    // local argv, not the loop). When the caller has no explicit command,
    // default to cd-into-the-remote-dir so a freshly created session lands in
    // the project.
    if let host = worktree.host {
      @Shared(.settingsFile) var settingsFile
      let hostPersistence = settingsFile.global.remoteSessionPersistenceEnabled
      let launch = ZmxAttach.RemoteSurfaceLaunch(
        host: host,
        surfaceID: surfaceID,
        userCommand: command,
        defaultCommand: Self.remoteDefaultShellCommand(
          remotePath: worktree.workingDirectory.path(percentEncoded: false)),
        hostPersistenceEnabled: hostPersistence,
      )
      return ResolvedLaunch(
        command: ZmxAttach.buildRemoteCommand(launch, localZmxExecutablePath: zmxExecutablePath),
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
    return ResolvedLaunch(
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
  /// single-quoted for the login shell that re-parses the session command.
  static func remoteDefaultShellCommand(remotePath: String) -> String? {
    let trimmed = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != "/" else { return nil }
    let quoted = "'" + trimmed.replacing("'", with: "'\\''") + "'"
    return "cd \(quoted) 2>/dev/null; exec \"$SHELL\" -l"
  }

  /// Tears down persistent zmx sessions for surfaces the user just closed.
  /// `isBundled` (not `executableURL`) is the gate so sessions created on a
  /// previous under-budget launch still tear down when this launch exceeds the
  /// socket budget. One analytics event + one `withTaskGroup` per call.
  /// `includeRemote` also tears down the host-side sessions of a remote
  /// worktree; only explicit close paths set it, so a non-explicit end (clean
  /// remote exit, deliberate host-side detach, or a reconnect abort) spares
  /// the host session. The remote kill is unconditional on explicit close (no
  /// per-surface persistence gate): a host session may exist from an earlier
  /// launch regardless of the current toggle, and the kill invocation is a
  /// silent no-op when nothing exists.
  func killZmxSessions(forSurfaceIDs surfaceIDs: [UUID], includeRemote: Bool = false) {
    guard !surfaceIDs.isEmpty else { return }
    let killLocal = zmxClient.isBundled()
    let host = includeRemote ? worktree.host : nil
    guard killLocal || host != nil else { return }
    let sessionIDs = surfaceIDs.map(ZmxSessionID.make(surfaceID:))
    let client = zmxClient
    analyticsClient.capture(
      "terminal_persistence_session_killed",
      [
        "reason": "user_close", "count": killLocal ? sessionIDs.count : 0,
        "remote_count": host == nil ? 0 : sessionIDs.count,
      ]
    )
    Task.detached {
      await withTaskGroup(of: Void.self) { group in
        for id in sessionIDs {
          group.addTask {
            await client.killSurfaceSessions(sessionID: id, remoteHost: host, killLocal: killLocal)
          }
        }
      }
    }
  }
}
