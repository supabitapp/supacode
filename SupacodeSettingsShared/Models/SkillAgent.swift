public nonisolated enum SkillAgent: String, Equatable, Sendable, CaseIterable, Codable {
  case claude
  case codex
  case copilot
  case grok
  case hermes
  case kimi
  case kiro
  case omp
  case opencode
  // swiftlint:disable:next identifier_name
  case pi

  /// Path under the user's home where the agent stores its config
  /// (e.g. `.claude`, `.codex`, `.copilot`, `.grok`, `.hermes`, `.kimi-code`, `.kiro`, `.omp/agent`, `.pi/agent`,
  /// `.config/opencode`).
  public var configDirectoryName: String {
    switch self {
    case .claude: ".claude"
    case .codex: ".codex"
    case .copilot: ".copilot"
    case .grok: ".grok"
    case .hermes: ".hermes"
    case .kimi: ".kimi-code"
    case .kiro: ".kiro"
    case .omp: ".omp/agent"
    case .opencode: ".config/opencode"
    case .pi: ".pi/agent"
    }
  }

  /// User-facing name (e.g. "Claude Code", "Codex").
  public var displayName: String {
    switch self {
    case .claude: "Claude Code"
    case .codex: "Codex"
    case .copilot: "Copilot CLI"
    case .grok: "Grok"
    case .hermes: "Hermes"
    case .kimi: "Kimi Code"
    case .kiro: "Kiro"
    case .omp: "Oh My Pi"
    case .opencode: "OpenCode"
    case .pi: "Pi"
    }
  }

  /// Asset catalog name for the agent's logo mark.
  public var assetName: String {
    switch self {
    case .claude: "claude-code-mark"
    case .codex: "codex-mark"
    case .copilot: "copilot-mark"
    case .grok: "grok-mark"
    case .hermes: "hermes-mark"
    case .kimi: "kimi-mark"
    case .kiro: "kiro-mark"
    case .omp: "omp-mark"
    case .opencode: "opencode-mark"
    case .pi: "pi-mark"
    }
  }
}
