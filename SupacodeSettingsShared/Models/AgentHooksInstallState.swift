public nonisolated enum AgentHooksInstallState: Equatable, Sendable {
  case checking
  case installed
  case notInstalled
  case installing
  case uninstalling
  case failed(String)

  public var isLoading: Bool {
    switch self {
    case .checking, .installing, .uninstalling: true
    default: false
    }
  }

  public var isInstalled: Bool {
    if case .installed = self { return true }
    return false
  }

  public var isFailure: Bool {
    if case .failed = self { return true }
    return false
  }

  public var errorMessage: String? {
    guard case .failed(let message) = self else { return nil }
    return message
  }
}

/// Identifies a specific hook feature for a specific agent.
public enum AgentHookSlot: Equatable, Sendable {
  case claudeProgress
  case claudeNotifications
  case codexProgress
  case codexNotifications
  case kiroProgress
  case kiroNotifications
  case piHooks
}
