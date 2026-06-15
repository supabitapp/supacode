import ComposableArchitecture
import Foundation

/// Per-agent unified install/uninstall surface. Wraps `AgentIntegration` so
/// reducers don't have to construct one per call. Tests stub this directly
/// instead of the underlying per-component clients.
public nonisolated struct AgentIntegrationClient: Sendable {
  public var state: @Sendable (SkillAgent) async -> AgentIntegrationState
  public var install: @Sendable (SkillAgent) async throws -> Void
  public var uninstall: @Sendable (SkillAgent) async throws -> Void

  public init(
    state: @escaping @Sendable (SkillAgent) async -> AgentIntegrationState,
    install: @escaping @Sendable (SkillAgent) async throws -> Void,
    uninstall: @escaping @Sendable (SkillAgent) async throws -> Void
  ) {
    self.state = state
    self.install = install
    self.uninstall = uninstall
  }
}

extension AgentIntegrationClient: DependencyKey {
  public static let liveValue = Self(
    state: { agent in
      AgentIntegrationFactory.make(for: agent).state()
    },
    install: { agent in
      try await AgentIntegrationFactory.make(for: agent).install()
    },
    uninstall: { agent in
      try AgentIntegrationFactory.make(for: agent).uninstall()
    }
  )

  public static let testValue = Self(
    state: { _ in .notInstalled },
    install: { _ in },
    uninstall: { _ in }
  )
}

extension DependencyValues {
  public var agentIntegrationClient: AgentIntegrationClient {
    get { self[AgentIntegrationClient.self] }
    set { self[AgentIntegrationClient.self] = newValue }
  }
}
