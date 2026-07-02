import Foundation

/// Builds an `AgentIntegration` for each agent by composing the existing
/// per-agent installers. The component list per agent is the canonical
/// definition of "what installing the integration means" for that agent.
nonisolated enum AgentIntegrationFactory {
  static func make(
    for agent: SkillAgent,
    homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
    fileManager: FileManager = .default
  ) -> AgentIntegration {
    switch agent {
    case .claude: claude(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
    case .codex: codex(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
    case .copilot: copilot(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
    case .kimi: kimi(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
    case .kiro: kiro(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
    case .pi: pi(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
    case .opencode: opencode(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
    }
  }

  // MARK: - Per-agent component lists.

  private static func claude(homeDirectoryURL: URL, fileManager: FileManager) -> AgentIntegration {
    let installer = ClaudeSettingsInstaller(
      homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
    let skill = CLISkillInstaller()
    return AgentIntegration(
      agent: .claude,
      components: [
        AgentIntegration.Component(
          kind: .unifiedHooks,
          state: { installer.installState() },
          install: { try installer.installAllHooks() },
          uninstall: { try installer.uninstallAllHooks() }
        ),
        skillComponent(agent: .claude, installer: skill),
      ]
    )
  }

  private static func codex(homeDirectoryURL: URL, fileManager: FileManager) -> AgentIntegration {
    let installer = CodexSettingsInstaller(
      homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
    let skill = CLISkillInstaller()
    return AgentIntegration(
      agent: .codex,
      components: [
        AgentIntegration.Component(
          kind: .unifiedHooks,
          state: { installer.installState() },
          install: { try await installer.installAllHooks() },
          uninstall: { try installer.uninstallAllHooks() }
        ),
        skillComponent(agent: .codex, installer: skill),
      ]
    )
  }

  private static func kimi(homeDirectoryURL: URL, fileManager: FileManager) -> AgentIntegration {
    let installer = KimiSettingsInstaller(
      homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
    let skill = CLISkillInstaller()
    return AgentIntegration(
      agent: .kimi,
      components: [
        AgentIntegration.Component(
          kind: .unifiedHooks,
          state: { installer.installState() },
          install: { try installer.installAllHooks() },
          uninstall: { try installer.uninstallAllHooks() }
        ),
        skillComponent(agent: .kimi, installer: skill),
      ]
    )
  }

  private static func kiro(homeDirectoryURL: URL, fileManager: FileManager) -> AgentIntegration {
    let installer = KiroSettingsInstaller(
      homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
    let skill = CLISkillInstaller()
    return AgentIntegration(
      agent: .kiro,
      components: [
        AgentIntegration.Component(
          kind: .unifiedHooks,
          state: { installer.installState() },
          install: { try await installer.installAllHooks() },
          uninstall: { try installer.uninstallAllHooks() }
        ),
        skillComponent(agent: .kiro, installer: skill),
      ]
    )
  }

  private static func pi(homeDirectoryURL: URL, fileManager: FileManager) -> AgentIntegration {
    let installer = PiSettingsInstaller(
      homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
    let skill = CLISkillInstaller()
    return AgentIntegration(
      agent: .pi,
      components: [
        AgentIntegration.Component(
          kind: .unifiedHooks,
          state: { installer.installState() },
          install: { try installer.install() },
          uninstall: { try installer.uninstall() }
        ),
        skillComponent(agent: .pi, installer: skill),
      ]
    )
  }

  private static func opencode(homeDirectoryURL: URL, fileManager: FileManager) -> AgentIntegration {
    let installer = OpenCodePluginInstaller(
      homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
    let skill = CLISkillInstaller()
    return AgentIntegration(
      agent: .opencode,
      components: [
        AgentIntegration.Component(
          kind: .unifiedHooks,
          state: { installer.installState() },
          install: { try installer.install() },
          uninstall: { try installer.uninstall() }
        ),
        skillComponent(agent: .opencode, installer: skill),
      ]
    )
  }

  private static func copilot(homeDirectoryURL: URL, fileManager: FileManager) -> AgentIntegration {
    let installer = CopilotHooksInstaller(
      homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
    let skill = CLISkillInstaller()
    return AgentIntegration(
      agent: .copilot,
      components: [
        AgentIntegration.Component(
          kind: .unifiedHooks,
          state: { installer.installState() },
          install: { try installer.install() },
          uninstall: { try installer.uninstall() }
        ),
        skillComponent(agent: .copilot, installer: skill),
      ]
    )
  }

  private static func skillComponent(
    agent: SkillAgent, installer: CLISkillInstaller
  ) -> AgentIntegration.Component {
    AgentIntegration.Component(
      kind: .cliSkill,
      state: { installer.installState(agent) },
      install: { try installer.install(agent) },
      uninstall: { try installer.uninstall(agent) }
    )
  }
}
