public nonisolated enum SkillAgent: Equatable, Sendable, CaseIterable {
  case claude
  case codex
  case kiro

  /// The dot-directory name under the user's home (e.g. `.claude`, `.codex`, `.kiro`).
  public var configDirectoryName: String {
    switch self {
    case .claude: ".claude"
    case .codex: ".codex"
    case .kiro: ".kiro"
    }
  }
}
