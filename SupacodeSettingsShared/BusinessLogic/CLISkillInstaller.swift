import Foundation

nonisolated struct CLISkillInstaller {
  private static let skillName = CLISkillContent.skillName
  let homeDirectoryURL: URL

  init(homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
    self.homeDirectoryURL = homeDirectoryURL
  }

  // MARK: - Shared paths.

  private func skillDir(for agent: SkillAgent) -> URL {
    homeDirectoryURL
      .appending(path: "\(agent.configDirectoryName)/skills/\(Self.skillName)", directoryHint: .isDirectory)
  }

  private func skillFile(for agent: SkillAgent) -> URL {
    skillDir(for: agent).appending(path: "SKILL.md", directoryHint: .notDirectory)
  }

  // MARK: - Check.

  func installState(_ agent: SkillAgent) -> ComponentInstallState {
    FileManager.default.fileExists(atPath: skillFile(for: agent).path(percentEncoded: false))
      ? .installed : .notInstalled
  }

  // MARK: - Install.

  func install(_ agent: SkillAgent) throws {
    let dir = skillDir(for: agent).path(percentEncoded: false)
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try skillContent(for: agent).write(to: skillFile(for: agent), atomically: true, encoding: .utf8)
    // Codex also requires an AGENTS.md alongside the skill.
    if agent == .codex {
      let agentsFile = skillDir(for: agent).appending(path: "AGENTS.md", directoryHint: .notDirectory)
      try CLISkillContent.codexAgentsMd.write(to: agentsFile, atomically: true, encoding: .utf8)
    }
  }

  // MARK: - Uninstall.

  func uninstall(_ agent: SkillAgent) throws {
    let dir = skillDir(for: agent).path(percentEncoded: false)
    guard FileManager.default.fileExists(atPath: dir) else { return }
    try FileManager.default.removeItem(atPath: dir)
  }

  // MARK: - Content.

  private func skillContent(for agent: SkillAgent) -> String {
    switch agent {
    case .claude: CLISkillContent.claudeSkill
    case .codex: CLISkillContent.codexSkillMd
    case .copilot: CLISkillContent.copilotSkillMd
    case .hermes: CLISkillContent.hermesSkillMd
    case .kimi: CLISkillContent.kimiSkillMd
    case .kiro: CLISkillContent.kiroSkillMd
    case .omp: CLISkillContent.ompSkillMd
    case .pi: CLISkillContent.piSkillMd
    case .opencode: CLISkillContent.opencodeSkillMd
    }
  }
}
