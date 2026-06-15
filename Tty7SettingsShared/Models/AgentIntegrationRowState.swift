/// UI-side install state for a per-agent integration row. Distinct from
/// `AgentIntegrationState` (which is the on-disk truth) because the row also
/// has to represent in-flight operations and the most recent failure.
public nonisolated enum AgentIntegrationRowState: Equatable, Sendable {
  case checking
  case ready(AgentIntegrationState)
  case installing
  case uninstalling
  case failed(String)

  /// Surfaced under the row when present.
  public var errorMessage: String? {
    if case .failed(let message) = self { return message }
    return nil
  }
}
