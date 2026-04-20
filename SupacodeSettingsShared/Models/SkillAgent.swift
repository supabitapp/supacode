public nonisolated enum SkillAgent: Equatable, Sendable, CaseIterable {
  case claude
  case codex
  case kiro
  // swiftlint:disable:next identifier_name
  case pi

  /// Path under the user's home where the agent stores its config
  /// (e.g. `.claude`, `.codex`, `.kiro`, `.pi/agent`).
  public var configDirectoryName: String {
    switch self {
    case .claude: ".claude"
    case .codex: ".codex"
    case .kiro: ".kiro"
    case .pi: ".pi/agent"
    }
  }
}
