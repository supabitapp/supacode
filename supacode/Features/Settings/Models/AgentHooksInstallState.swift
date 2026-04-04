nonisolated enum AgentHooksInstallState: Equatable, Sendable {
  case checking
  case installed
  case notInstalled
  case installing
  case uninstalling
  case failed(String)

  var isLoading: Bool {
    switch self {
    case .checking, .installing, .uninstalling: true
    default: false
    }
  }

  var isInstalled: Bool {
    if case .installed = self { return true }
    return false
  }

  var isFailure: Bool {
    if case .failed = self { return true }
    return false
  }

  var errorMessage: String? {
    guard case .failed(let message) = self else { return nil }
    return message
  }
}

/// Identifies a specific hook feature for a specific agent.
enum AgentHookSlot: Equatable, Sendable {
  case claudeProgress
  case claudeNotifications
  case codexProgress
  case codexNotifications
}
