import Foundation

struct AgentProvider: Identifiable, Hashable, Sendable, Codable {
  let id: String
  let name: String
  let cli: String
  let autoApproveFlag: String?
  let initialPromptFlag: String?
  let icon: String

  static let registry: [AgentProvider] = [
    AgentProvider(
      id: "claude",
      name: "Claude Code",
      cli: "claude",
      autoApproveFlag: "--dangerously-skip-permissions",
      initialPromptFlag: "--prompt",
      icon: "brain.head.profile"
    ),
    AgentProvider(
      id: "codex",
      name: "Codex CLI",
      cli: "codex",
      autoApproveFlag: "--auto-approve",
      initialPromptFlag: nil,
      icon: "terminal"
    ),
    AgentProvider(
      id: "aider",
      name: "Aider",
      cli: "aider",
      autoApproveFlag: "--yes",
      initialPromptFlag: "--message",
      icon: "wrench.and.screwdriver"
    ),
    AgentProvider(
      id: "goose",
      name: "Goose",
      cli: "goose",
      autoApproveFlag: nil,
      initialPromptFlag: nil,
      icon: "bird"
    ),
    AgentProvider(
      id: "gemini",
      name: "Gemini CLI",
      cli: "gemini",
      autoApproveFlag: nil,
      initialPromptFlag: nil,
      icon: "sparkles"
    ),
    AgentProvider(
      id: "amp",
      name: "Amp",
      cli: "amp",
      autoApproveFlag: nil,
      initialPromptFlag: nil,
      icon: "bolt"
    ),
  ]

  static let byID: [String: AgentProvider] = {
    Dictionary(uniqueKeysWithValues: registry.map { ($0.id, $0) })
  }()
}
