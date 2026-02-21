import Foundation

enum CodingAgent: String, CaseIterable, Identifiable, Sendable {
  case claude
  case codex

  var id: String { rawValue }

  var label: String {
    switch self {
    case .claude:
      "Claude Code"
    case .codex:
      "Codex"
    }
  }

  var binaryName: String {
    switch self {
    case .claude:
      "claude"
    case .codex:
      "codex"
    }
  }

  var wrapperFileName: String {
    binaryName
  }
}

struct CodingAgentIntegrationStatus: Equatable, Sendable {
  var claudeEnabled: Bool
  var codexEnabled: Bool

  static let disabled = CodingAgentIntegrationStatus(
    claudeEnabled: false,
    codexEnabled: false
  )

  var isEnabled: Bool {
    claudeEnabled || codexEnabled
  }

  func isEnabled(for agent: CodingAgent) -> Bool {
    switch agent {
    case .claude:
      claudeEnabled
    case .codex:
      codexEnabled
    }
  }

  mutating func setEnabled(_ enabled: Bool, for agent: CodingAgent) {
    switch agent {
    case .claude:
      claudeEnabled = enabled
    case .codex:
      codexEnabled = enabled
    }
  }
}
