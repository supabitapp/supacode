import ComposableArchitecture
import Foundation

/// Per-agent unified install/uninstall surface. Wraps `AgentIntegration` so
/// reducers don't have to construct one per call. Tests stub this directly
/// instead of the underlying per-component clients.
public nonisolated struct AgentIntegrationClient: Sendable {
  /// Throws when the on-disk state can't be determined (see `AgentFileProbe`).
  /// Callers must not treat that as "not installed".
  public var state: @Sendable (AgentInstallTarget) async throws -> AgentIntegrationState
  public var install: @Sendable (AgentInstallTarget) async throws -> Void
  public var uninstall: @Sendable (AgentInstallTarget) async throws -> Void

  public init(
    state: @escaping @Sendable (AgentInstallTarget) async throws -> AgentIntegrationState,
    install: @escaping @Sendable (AgentInstallTarget) async throws -> Void,
    uninstall: @escaping @Sendable (AgentInstallTarget) async throws -> Void
  ) {
    self.state = state
    self.install = install
    self.uninstall = uninstall
  }
}

extension AgentIntegrationClient: DependencyKey {
  public static let liveValue = Self(
    state: { target in
      try AgentIntegrationFactory.make(
        for: target.agent, configDirectoryURL: target.configDirectoryURL
      ).state()
    },
    install: { target in
      try await AgentIntegrationFactory.make(
        for: target.agent, configDirectoryURL: target.configDirectoryURL
      ).install()
    },
    uninstall: { target in
      try AgentIntegrationFactory.make(
        for: target.agent, configDirectoryURL: target.configDirectoryURL
      ).uninstall()
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
