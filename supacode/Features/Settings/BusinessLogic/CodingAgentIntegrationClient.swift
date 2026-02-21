import ComposableArchitecture

struct CodingAgentIntegrationClient: Sendable {
  var status: @MainActor @Sendable () async throws -> CodingAgentIntegrationStatus
  var setEnabled: @MainActor @Sendable (CodingAgent, Bool) async throws -> Void
}

extension CodingAgentIntegrationClient: DependencyKey {
  static let liveValue = CodingAgentIntegrationClient(
    status: {
      try CodingAgentIntegrationManager().status()
    },
    setEnabled: { agent, enabled in
      try CodingAgentIntegrationManager().setEnabled(agent, enabled: enabled)
    }
  )

  static let testValue = CodingAgentIntegrationClient(
    status: { .disabled },
    setEnabled: { _, _ in }
  )
}

extension DependencyValues {
  var codingAgentIntegrationClient: CodingAgentIntegrationClient {
    get { self[CodingAgentIntegrationClient.self] }
    set { self[CodingAgentIntegrationClient.self] = newValue }
  }
}
