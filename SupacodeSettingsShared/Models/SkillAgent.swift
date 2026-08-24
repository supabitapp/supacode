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

  /// True when Supacode can WRITE this agent's whole integration into a chosen
  /// config directory. It does NOT mean Supacode drives the agent from there, or
  /// that the agent can even be pointed at it: honoring the relocated dir is the
  /// user's job (e.g. `CLAUDE_CONFIG_DIR`). False only when the integration spans
  /// fixed paths a relocated dir can't cover: Antigravity's `~/.gemini` siblings
  /// and Kiro's absolute `~/.kiro` paths.
  public var supportsCustomConfigFolder: Bool {
    self != .antigravity && self != .kiro
  }

  /// Whether the agent surfaces a given capability, for the settings grid.
  /// Hand-maintained from each agent's installed hook events (not exposed as a
  /// readable set). Keep in sync with the per-agent hook definitions.
  public func supports(_ feature: AgentFeature) -> Bool {
    switch feature {
    case .activityBadge, .idleBadge, .skills:
      true
    case .inputNeededBadge:
      self == .claude || self == .grok || self == .copilot || self == .kimi || self == .opencode
    case .errorDetection:
      self == .claude || self == .antigravity
    case .compactionBadge:
      self == .claude
    case .notifications:
      self != .opencode
    case .customFolder:
      supportsCustomConfigFolder
    }
  }
}

/// A capability surfaced by an installed agent integration, rendered as one row
/// of the settings capability grid. Ordered as it should read top-to-bottom.
public nonisolated enum AgentFeature: String, CaseIterable, Sendable {
  case activityBadge
  case idleBadge
  case inputNeededBadge
  case errorDetection
  case compactionBadge
  case notifications
  case skills
  case customFolder

  /// User-facing row label.
  public var title: String {
    switch self {
    case .activityBadge: "Activity badge"
    case .idleBadge: "Idle badge"
    case .inputNeededBadge: "Input-needed badge"
    case .errorDetection: "Error detection"
    case .compactionBadge: "Compaction badge"
    case .notifications: "Notifications"
    case .skills: "Skills"
    case .customFolder: "Custom folder"
    }
  }
}
