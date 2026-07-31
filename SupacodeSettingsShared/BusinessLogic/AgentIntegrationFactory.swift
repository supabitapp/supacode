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
    let components =
      switch agent {
      case .antigravity: antigravity(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
      case .claude: claude(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
      case .codex: codex(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
      case .copilot: copilot(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
      case .grok: grok(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
      case .hermes: hermes(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
      case .kimi: kimi(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
      case .kiro: kiro(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
      case .omp: omp(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
      case .pi: pi(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
      case .opencode: opencode(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
      }
    // Gate install on the agent's own config directory existing, as a proxy for
    // the CLI being installed, so Supacode never bootstraps a harness from
    // nothing. Wiring it here (the only construction path) makes the gate a
    // construction-time invariant.
    return AgentIntegration(
      agent: agent,
      components: components,
      requiredDirectory: homeDirectoryURL.appending(path: agent.configDirectoryName),
      fileManager: fileManager
    )
  }

  // MARK: - Per-agent component lists.

  private static func antigravity(homeDirectoryURL: URL, fileManager: FileManager)
    -> [AgentIntegration.Component]
  {
    let installer = AntigravitySettingsInstaller(
      homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
    let skill = CLISkillInstaller(homeDirectoryURL: homeDirectoryURL)
    return [
      AgentIntegration.Component(
        kind: .unifiedHooks,
        state: { installer.installState() },
        install: { try installer.installAllHooks() },
        uninstall: { try installer.uninstallAllHooks() }
      ),
      skillComponent(agent: .antigravity, installer: skill),
    ]
  }

  private static func claude(homeDirectoryURL: URL, fileManager: FileManager)
    -> [AgentIntegration.Component]
  {
    let installer = ClaudeSettingsInstaller(
      homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
    let skill = CLISkillInstaller(homeDirectoryURL: homeDirectoryURL)
    return [
      AgentIntegration.Component(
        kind: .unifiedHooks,
        state: { installer.installState() },
        install: { try installer.installAllHooks() },
        uninstall: { try installer.uninstallAllHooks() }
      ),
      skillComponent(agent: .claude, installer: skill),
    ]
  }

  private static func codex(homeDirectoryURL: URL, fileManager: FileManager)
    -> [AgentIntegration.Component]
  {
    let installer = CodexSettingsInstaller(
      homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
    let skill = CLISkillInstaller(homeDirectoryURL: homeDirectoryURL)
    return [
      AgentIntegration.Component(
        kind: .unifiedHooks,
        state: { installer.installState() },
        install: { try await installer.installAllHooks() },
        uninstall: { try installer.uninstallAllHooks() }
      ),
      skillComponent(agent: .codex, installer: skill),
    ]
  }

  private static func grok(homeDirectoryURL: URL, fileManager: FileManager)
    -> [AgentIntegration.Component]
  {
    let installer = GrokSettingsInstaller(
      homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
    let skill = CLISkillInstaller(homeDirectoryURL: homeDirectoryURL)
    return [
      AgentIntegration.Component(
        kind: .unifiedHooks,
        state: { installer.installState() },
        install: { try installer.installAllHooks() },
        uninstall: { try installer.uninstallAllHooks() }
      ),
      skillComponent(agent: .grok, installer: skill),
    ]
  }

  private static func kimi(homeDirectoryURL: URL, fileManager: FileManager)
    -> [AgentIntegration.Component]
  {
    let installer = KimiSettingsInstaller(
      homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
    let skill = CLISkillInstaller(homeDirectoryURL: homeDirectoryURL)
    return [
      AgentIntegration.Component(
        kind: .unifiedHooks,
        state: { installer.installState() },
        install: { try installer.installAllHooks() },
        uninstall: { try installer.uninstallAllHooks() }
      ),
      skillComponent(agent: .kimi, installer: skill),
    ]
  }

  private static func hermes(homeDirectoryURL: URL, fileManager: FileManager)
    -> [AgentIntegration.Component]
  {
    let installer = HermesPluginInstaller(
      homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
    let skill = CLISkillInstaller(homeDirectoryURL: homeDirectoryURL)
    return [
      AgentIntegration.Component(
        kind: .unifiedHooks,
        state: { installer.installState() },
        install: { try installer.install() },
        uninstall: { try installer.uninstall() }
      ),
      skillComponent(agent: .hermes, installer: skill),
    ]
  }

  private static func kiro(homeDirectoryURL: URL, fileManager: FileManager)
    -> [AgentIntegration.Component]
  {
    let installer = KiroSettingsInstaller(
      homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
    let skill = CLISkillInstaller(homeDirectoryURL: homeDirectoryURL)
    return [
      AgentIntegration.Component(
        kind: .unifiedHooks,
        state: { installer.installState() },
        install: { try await installer.installAllHooks() },
        uninstall: { try installer.uninstallAllHooks() }
      ),
      skillComponent(agent: .kiro, installer: skill),
    ]
  }

  private static func omp(homeDirectoryURL: URL, fileManager: FileManager)
    -> [AgentIntegration.Component]
  {
    let installer = OmpSettingsInstaller(
      homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
    let skill = CLISkillInstaller(homeDirectoryURL: homeDirectoryURL)
    return [
      AgentIntegration.Component(
        kind: .unifiedHooks,
        state: { installer.installState() },
        install: { try installer.install() },
        uninstall: { try installer.uninstall() }
      ),
      skillComponent(agent: .omp, installer: skill),
    ]
  }

  private static func pi(homeDirectoryURL: URL, fileManager: FileManager)
    -> [AgentIntegration.Component]
  {
    let installer = PiSettingsInstaller(
      homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
    let skill = CLISkillInstaller(homeDirectoryURL: homeDirectoryURL)
    return [
      AgentIntegration.Component(
        kind: .unifiedHooks,
        state: { installer.installState() },
        install: { try installer.install() },
        uninstall: { try installer.uninstall() }
      ),
      skillComponent(agent: .pi, installer: skill),
    ]
  }

  private static func opencode(homeDirectoryURL: URL, fileManager: FileManager)
    -> [AgentIntegration.Component]
  {
    let installer = OpenCodePluginInstaller(
      homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
    let skill = CLISkillInstaller(homeDirectoryURL: homeDirectoryURL)
    return [
      AgentIntegration.Component(
        kind: .unifiedHooks,
        state: { installer.installState() },
        install: { try installer.install() },
        uninstall: { try installer.uninstall() }
      ),
      skillComponent(agent: .opencode, installer: skill),
    ]
  }

  private static func copilot(homeDirectoryURL: URL, fileManager: FileManager)
    -> [AgentIntegration.Component]
  {
    let installer = CopilotHooksInstaller(
      homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
    let skill = CLISkillInstaller(homeDirectoryURL: homeDirectoryURL)
    return [
      AgentIntegration.Component(
        kind: .unifiedHooks,
        state: { installer.installState() },
        install: { try installer.install() },
        uninstall: { try installer.uninstall() }
      ),
      skillComponent(agent: .copilot, installer: skill),
    ]
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
