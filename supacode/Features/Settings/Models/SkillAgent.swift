nonisolated enum SkillAgent: Equatable, Sendable, CaseIterable {
  case claude
  case codex

  /// The dot-directory name under the user's home (e.g. `.claude`, `.codex`).
  var configDirectoryName: String {
    switch self {
    case .claude: ".claude"
    case .codex: ".codex"
    }
  }
}
