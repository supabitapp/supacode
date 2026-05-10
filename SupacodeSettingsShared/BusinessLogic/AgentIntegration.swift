import Foundation

/// A per-agent integration composed of one or more independently-checked
/// components (hook groups, skill files, …). Composes the existing per-agent
/// installers — the source of truth stays the on-disk files those installers
/// edit, so a user hand-removing a hook is reflected the next time `state()`
/// is called.
///
/// `@unchecked Sendable` because the closure components may capture per-agent
/// installer values that hold a `FileManager` (not formally Sendable); those
/// captures are stateless value types in practice.
public nonisolated struct AgentIntegration: @unchecked Sendable {
  public let agent: SkillAgent

  /// Components in install order. `install()` runs front-to-back and
  /// `uninstall()` reverses the order so any inter-component setup (e.g.
  /// Codex's `enable hooks` flag) unwinds last.
  public let components: [Component]

  public init(agent: SkillAgent, components: [Component]) {
    self.agent = agent
    self.components = components
  }

  public struct Component {
    public let kind: Kind
    public let isInstalled: () -> Bool
    public let install: () async throws -> Void
    public let uninstall: () throws -> Void

    public init(
      kind: Kind,
      isInstalled: @escaping () -> Bool,
      install: @escaping () async throws -> Void,
      uninstall: @escaping () throws -> Void
    ) {
      self.kind = kind
      self.isInstalled = isInstalled
      self.install = install
      self.uninstall = uninstall
    }

    public enum Kind: String, Sendable, Equatable, CaseIterable {
      case progressHooks
      case notificationHooks
      /// Single combined hook block (Pi).
      case unifiedHooks
      case cliSkill
    }
  }
}

/// Aggregate install state for a `AgentIntegration`.
public nonisolated enum AgentIntegrationState: Equatable, Sendable {
  case notInstalled
  case partiallyInstalled(missing: [AgentIntegration.Component.Kind])
  case installed
}

nonisolated extension AgentIntegration {
  public func state() -> AgentIntegrationState {
    let missing = components.filter { !$0.isInstalled() }.map(\.kind)
    if missing.isEmpty { return .installed }
    if missing.count == components.count { return .notInstalled }
    return .partiallyInstalled(missing: missing)
  }

  /// Installs every component in order. On partial failure the components
  /// that succeeded are rolled back so the user is never left in a state
  /// where some hooks are present and others aren't.
  public func install() async throws {
    var rollback: [Component] = []
    do {
      for component in components {
        try await component.install()
        rollback.append(component)
      }
    } catch {
      for component in rollback.reversed() {
        try? component.uninstall()
      }
      throw error
    }
  }

  /// Uninstalls every component (in reverse order). Failures on individual
  /// components don't stop the sweep — they're collected and the first one
  /// is rethrown after the sweep completes, so a stuck artifact never blocks
  /// removing the rest.
  public func uninstall() throws {
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
