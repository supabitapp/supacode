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
    let state: () -> ComponentInstallState
    let install: () async throws -> Void
    let uninstall: () throws -> Void

    init(
      kind: Kind,
      state: @escaping () -> ComponentInstallState,
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
      case unifiedHooks
      case cliSkill
    }
  }
}

/// State of a single integration component on disk. Hook components can be
/// `.outdated` (some expected commands present but not all) — the user has
/// an older Supacode version's hooks installed and needs to upgrade. Skill
/// components only ever report `.notInstalled` or `.installed`.
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

nonisolated extension AgentIntegration {
  func state() -> AgentIntegrationState {
    let states = components.map { $0.state() }
    if states.allSatisfy({ $0 == .installed }) { return .installed }
    if states.allSatisfy({ $0 == .notInstalled }) { return .notInstalled }
    return .outdated
  }

  /// Installs every component in order. On partial failure the components
  /// that succeeded are rolled back so the user is never left in a state
  /// where some hooks are present and others aren't.
  func install() async throws {
    if let requiredDirectory {
      var isDirectory: ObjCBool = false
      let exists = fileManager.fileExists(
        atPath: requiredDirectory.path(percentEncoded: false), isDirectory: &isDirectory)
      guard exists, isDirectory.boolValue else {
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
        if firstError == nil { firstError = error }
      }
    }
    if let firstError { throw firstError }
  }
}
