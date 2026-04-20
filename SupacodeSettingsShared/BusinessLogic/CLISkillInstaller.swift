import Foundation

nonisolated struct CLISkillInstaller {
  private static let skillName = CLISkillContent.skillName

  // MARK: - Shared paths.

  private static func skillDir(for agent: SkillAgent) -> URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "\(agent.configDirectoryName)/skills/\(skillName)", directoryHint: .isDirectory)
  }

  private static func skillFile(for agent: SkillAgent) -> URL {
    skillDir(for: agent).appending(path: "SKILL.md", directoryHint: .notDirectory)
  }

  // MARK: - Check.

  func isInstalled(_ agent: SkillAgent) -> Bool {
    FileManager.default.fileExists(atPath: Self.skillFile(for: agent).path(percentEncoded: false))
  }

  // MARK: - Install.

  func install(_ agent: SkillAgent) throws {
    let dir = Self.skillDir(for: agent).path(percentEncoded: false)
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try skillContent(for: agent).write(to: Self.skillFile(for: agent), atomically: true, encoding: .utf8)
    // Codex also requires an AGENTS.md alongside the skill.
    if agent == .codex {
      let agentsFile = Self.skillDir(for: agent).appending(path: "AGENTS.md", directoryHint: .notDirectory)
      try CLISkillContent.codexAgentsMd.write(to: agentsFile, atomically: true, encoding: .utf8)
    }
  }

  // MARK: - Uninstall.

  func uninstall(_ agent: SkillAgent) throws {
    let dir = Self.skillDir(for: agent).path(percentEncoded: false)
    guard FileManager.default.fileExists(atPath: dir) else { return }
    try FileManager.default.removeItem(atPath: dir)
  }

  // MARK: - Content.

  private func skillContent(for agent: SkillAgent) -> String {
    switch agent {
    case .claude: CLISkillContent.claudeSkill
    case .codex: CLISkillContent.codexSkillMd
    case .kiro: CLISkillContent.kiroSkillMd
    case .pi: CLISkillContent.piSkillMd
    }
  }
}
