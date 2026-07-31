import Foundation

public nonisolated enum SkillAgent: String, Equatable, Sendable, CaseIterable, Codable {
  case antigravity
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
  /// (e.g. `.gemini/antigravity-cli`, `.claude`, `.codex`, `.copilot`, `.grok`,
  /// `.hermes`, `.kimi-code`, `.kiro`, `.omp/agent`, `.pi/agent`, `.config/opencode`).
  public var configDirectoryName: String {
    switch self {
    case .antigravity: ".gemini/antigravity-cli"
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
    case .antigravity: "Google Antigravity"
    case .claude: "Claude Code"
    case .codex: "Codex"
    case .copilot: "Copilot CLI"
    case .grok: "Grok Code"
    case .hermes: "Hermes"
    case .kimi: "Kimi Code"
    case .kiro: "Kiro CLI"
    case .omp: "Oh My Pi"
    case .opencode: "OpenCode"
    case .pi: "Pi"
    }
  }

  /// Asset catalog name for the agent's logo mark.
  public var assetName: String {
    switch self {
    case .antigravity: "antigravity-mark"
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

  /// All agents ordered by their user-facing `displayName`, for settings lists.
  /// Computed once: the inputs are static, so re-sorting per access is waste.
  public static let allCasesByDisplayName: [SkillAgent] =
    allCases.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
}
