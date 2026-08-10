import Foundation

private nonisolated let agentIntegrationLogger = SupaLogger("Settings")

/// A per-agent integration composed of one or more independently-checked
/// components (hook groups, skill files, …). Composes the existing per-agent
/// installers — the source of truth stays the on-disk files those installers
/// edit, so a user hand-removing a hook is reflected the next time `state()`
/// is called.
///
/// `@unchecked Sendable` because the closure components may capture per-agent
/// installer values that hold a `FileManager` (not formally Sendable); those
/// captures are stateless value types in practice.
nonisolated struct AgentIntegration: @unchecked Sendable {
  let agent: SkillAgent

  /// Components in install order. `install()` runs front-to-back and
  /// `uninstall()` reverses the order so any inter-component setup (e.g.
  /// Codex's `enable hooks` flag) unwinds last.
  let components: [Component]

  /// The agent's own config directory, which must already exist for `install()`
  /// to run: a proxy for "the CLI is installed" so Supacode never bootstraps a
  /// harness the user hasn't set up. Supacode's subdirectories under it (hooks,
  /// skills, …) are still created. Nil disables the gate (unit tests).
  let requiredDirectory: URL?

  /// File manager the install gate probes with; matches the installers'.
  let fileManager: FileManager

  init(
    agent: SkillAgent,
    components: [Component],
    requiredDirectory: URL? = nil,
    fileManager: FileManager = .default
  ) {
    self.agent = agent
    self.components = components
    self.requiredDirectory = requiredDirectory
    self.fileManager = fileManager
  }

  struct Component {
    let kind: Kind
    /// Throws when the on-disk state can't be determined, so a failed read is
    /// never reported as a verdict.
    let state: () throws -> ComponentInstallState
    let install: () async throws -> Void
    let uninstall: () throws -> Void

    init(
      kind: Kind,
      state: @escaping () throws -> ComponentInstallState,
      install: @escaping () async throws -> Void,
      uninstall: @escaping () throws -> Void
    ) {
      self.kind = kind
      self.state = state
      self.install = install
      self.uninstall = uninstall
    }

    enum Kind: String, Sendable, Equatable, CaseIterable {
      /// All hooks (progress + notification) installed in one shot.
      case hooks
      /// Both generated skills (`supacode-cli` and `supacode-deeplinks`) as one unit.
      case skills
    }
  }
}

/// State of a single integration component on disk. Hook components can be
/// `.outdated` (some expected commands present but not all) — the user has
/// an older Supacode version's hooks installed and needs to upgrade. Skill
/// components report `.outdated` when only some of the skill files exist, or
/// their content no longer matches the bundled markdown.
public nonisolated enum ComponentInstallState: Equatable, Sendable {
  case notInstalled
  case installed
  case outdated
}

/// Aggregate install state for an `AgentIntegration`. `.outdated` covers both
/// "some components missing" and "some components stale" — both demand the
/// same user action (run install again to upgrade).
public nonisolated enum AgentIntegrationState: Equatable, Sendable {
  case notInstalled
  case installed
  case outdated
}

/// Raised when an integration can't be installed because the agent itself
/// isn't set up: its config directory is absent.
public nonisolated enum AgentIntegrationError: Error, LocalizedError, Equatable {
  case notInstalled(SkillAgent)

  public var errorDescription: String? {
    switch self {
    case .notInstalled(let agent):
      "\(agent.displayName) isn't installed yet. Install \(agent.displayName), then add its Supacode integration."
    }
  }
}

/// Raised when a file exists but can't be read, so no install state can be
/// derived from it. Transient by nature (a wedged filesystem extension, fd
/// exhaustion, a stuck vnode), so callers re-probe rather than record a failure.
public nonisolated struct AgentFileUnreadableError: Error, LocalizedError, Equatable {
  public let displayPath: String
  public let reason: String

  public init(displayPath: String, reason: String) {
    self.displayPath = displayPath
    self.reason = reason
  }

  public var errorDescription: String? {
    "Couldn't read \(displayPath): \(reason)"
  }
}

/// Filesystem reads that tell "genuinely absent" apart from "couldn't tell".
/// `FileManager.fileExists` cannot: it is stat-backed and collapses every errno
/// into `false`, so a denied stat is indistinguishable from a fresh machine.
nonisolated enum AgentFileProbe {
  /// `nil` when the file genuinely doesn't exist (a fresh install); throws
  /// `AgentFileUnreadableError` for every other read failure.
  static func data(at url: URL) throws -> Data? {
    do {
      return try Data(contentsOf: url)
    } catch {
      guard isFileNotFound(error) else { throw unreadable(url, error) }
      return nil
    }
  }

  /// UTF-8 counterpart of `data(at:)`. A file that exists but isn't valid
  /// UTF-8 is unreadable, not absent.
  static func text(at url: URL) throws -> String? {
    guard let data = try data(at: url) else { return nil }
    guard let text = String(data: data, encoding: .utf8) else {
      throw AgentFileUnreadableError(displayPath: displayPath(url), reason: "The file isn't valid UTF-8.")
    }
    return text
  }

  /// Throws rather than answering `false` when the absence can't be confirmed,
  /// so a wedge never reads as "the agent isn't installed".
  static func directoryExists(at url: URL, fileManager: FileManager) throws -> Bool {
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) {
      return isDirectory.boolValue
    }
    do {
      return try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
    } catch {
      guard isFileNotFound(error) else { throw unreadable(url, error) }
      return false
    }
  }

  /// Only a genuine "no such file" counts as absence; everything else (EPERM,
  /// EIO, EMFILE) means the answer is unknown.
  static func isFileNotFound(_ error: Error) -> Bool {
    let nsError = error as NSError
    switch nsError.domain {
    case NSCocoaErrorDomain:
      return nsError.code == NSFileReadNoSuchFileError || nsError.code == NSFileNoSuchFileError
    case NSPOSIXErrorDomain:
      return nsError.code == Int(ENOENT)
    default:
      return false
    }
  }

  private static func unreadable(_ url: URL, _ error: Error) -> AgentFileUnreadableError {
    AgentFileUnreadableError(
      displayPath: displayPath(url),
      reason: (error as NSError).localizedFailureReason ?? error.localizedDescription
    )
  }

  /// Home-relative so the message names the file the way the user would.
  private static func displayPath(_ url: URL) -> String {
    (url.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
  }
}

nonisolated extension AgentIntegration {
  /// Throws when any component can't determine its state: aggregating a partial
  /// read to `.outdated` would arm an unattended rewrite of files we can't read.
  func state() throws -> AgentIntegrationState {
    let states = try components.map { try $0.state() }
    if states.allSatisfy({ $0 == .installed }) { return .installed }
    if states.allSatisfy({ $0 == .notInstalled }) { return .notInstalled }
    return .outdated
  }

  /// Installs every component in order. On partial failure the components
  /// that succeeded are rolled back so the user is never left in a state
  /// where some hooks are present and others aren't.
  func install() async throws {
    if let requiredDirectory {
      // Throws rather than reporting absence, so a wedge never tells the user
      // to install an agent they already have.
      guard try AgentFileProbe.directoryExists(at: requiredDirectory, fileManager: fileManager) else {
        throw AgentIntegrationError.notInstalled(agent)
      }
    }
    var rollback: [Component] = []
    do {
      for component in components {
        try await component.install()
        rollback.append(component)
      }
    } catch {
      for component in rollback.reversed() {
        do {
          try component.uninstall()
        } catch let rollbackError {
          // Keep sweeping so the rest unwinds, but a failed rollback step is
          // exactly the "some hooks present, others not" state worth recording.
          agentIntegrationLogger.error(
            "Rolling back \(agent.rawValue) integration failed: \(rollbackError)")
        }
      }
      throw error
    }
  }

  /// Uninstalls every component (in reverse order). Failures on individual
  /// components don't stop the sweep — they're collected and the first one
  /// is rethrown after the sweep completes, so a stuck artifact never blocks
  /// removing the rest.
  func uninstall() throws {
    var firstError: Error?
    for component in components.reversed() {
      do {
        try component.uninstall()
      } catch {
        // Every failure is logged; only the first rethrows.
        agentIntegrationLogger.error(
          "Uninstalling \(agent.rawValue) \(component.kind.rawValue) failed: \(error)")
        if firstError == nil { firstError = error }
      }
    }
    if let firstError { throw firstError }
  }
}
