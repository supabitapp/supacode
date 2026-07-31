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
    return [
      AgentIntegration.Component(
        kind: .hooks,
        state: { installer.installState() },
        install: { try installer.installAllHooks() },
        uninstall: { try installer.uninstallAllHooks() }
      ),
      skillsComponent(agent: .antigravity, homeDirectoryURL: homeDirectoryURL),
    ]
  }

  private static func claude(homeDirectoryURL: URL, fileManager: FileManager)
    -> [AgentIntegration.Component]
  {
    let installer = ClaudeSettingsInstaller(
      homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
    return [
      AgentIntegration.Component(
        kind: .hooks,
        state: { installer.installState() },
        install: { try installer.installAllHooks() },
        uninstall: { try installer.uninstallAllHooks() }
      ),
      skillsComponent(agent: .claude, homeDirectoryURL: homeDirectoryURL),
    ]
  }

  private static func codex(homeDirectoryURL: URL, fileManager: FileManager)
    -> [AgentIntegration.Component]
  {
    let installer = CodexSettingsInstaller(
      homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
    return [
      AgentIntegration.Component(
        kind: .hooks,
        state: { installer.installState() },
        install: { try await installer.installAllHooks() },
        uninstall: { try installer.uninstallAllHooks() }
      ),
      skillsComponent(agent: .codex, homeDirectoryURL: homeDirectoryURL),
    ]
  }

  private static func grok(homeDirectoryURL: URL, fileManager: FileManager)
    -> [AgentIntegration.Component]
  {
    let installer = GrokSettingsInstaller(
      homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
    return [
      AgentIntegration.Component(
        kind: .hooks,
        state: { installer.installState() },
        install: { try installer.installAllHooks() },
        uninstall: { try installer.uninstallAllHooks() }
      ),
      skillsComponent(agent: .grok, homeDirectoryURL: homeDirectoryURL),
    ]
  }

  private static func kimi(homeDirectoryURL: URL, fileManager: FileManager)
    -> [AgentIntegration.Component]
  {
    let installer = KimiSettingsInstaller(
      homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
    return [
      AgentIntegration.Component(
        kind: .hooks,
        state: { installer.installState() },
        install: { try installer.installAllHooks() },
        uninstall: { try installer.uninstallAllHooks() }
      ),
      skillsComponent(agent: .kimi, homeDirectoryURL: homeDirectoryURL),
    ]
  }

  private static func hermes(homeDirectoryURL: URL, fileManager: FileManager)
    -> [AgentIntegration.Component]
  {
    let installer = HermesPluginInstaller(
      homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
    return [
      AgentIntegration.Component(
        kind: .hooks,
        state: { installer.installState() },
        install: { try installer.install() },
        uninstall: { try installer.uninstall() }
      ),
      skillsComponent(agent: .hermes, homeDirectoryURL: homeDirectoryURL),
    ]
  }

  private static func kiro(homeDirectoryURL: URL, fileManager: FileManager)
    -> [AgentIntegration.Component]
  {
    let installer = KiroSettingsInstaller(
      homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
    return [
      AgentIntegration.Component(
        kind: .hooks,
        state: { installer.installState() },
        install: { try await installer.installAllHooks() },
        uninstall: { try installer.uninstallAllHooks() }
      ),
      skillsComponent(agent: .kiro, homeDirectoryURL: homeDirectoryURL),
    ]
  }

  private static func omp(homeDirectoryURL: URL, fileManager: FileManager)
    -> [AgentIntegration.Component]
  {
    let installer = OmpSettingsInstaller(
      homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
    return [
      AgentIntegration.Component(
        kind: .hooks,
        state: { installer.installState() },
        install: { try installer.install() },
        uninstall: { try installer.uninstall() }
      ),
      skillsComponent(agent: .omp, homeDirectoryURL: homeDirectoryURL),
    ]
  }

  private static func pi(homeDirectoryURL: URL, fileManager: FileManager)
    -> [AgentIntegration.Component]
  {
    let installer = PiSettingsInstaller(
      homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
    return [
      AgentIntegration.Component(
        kind: .hooks,
        state: { installer.installState() },
        install: { try installer.install() },
        uninstall: { try installer.uninstall() }
      ),
      skillsComponent(agent: .pi, homeDirectoryURL: homeDirectoryURL),
    ]
  }

  private static func opencode(homeDirectoryURL: URL, fileManager: FileManager)
    -> [AgentIntegration.Component]
  {
    let installer = OpenCodePluginInstaller(
      homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
    return [
      AgentIntegration.Component(
        kind: .hooks,
        state: { installer.installState() },
        install: { try installer.install() },
        uninstall: { try installer.uninstall() }
      ),
      skillsComponent(agent: .opencode, homeDirectoryURL: homeDirectoryURL),
    ]
  }

  private static func copilot(homeDirectoryURL: URL, fileManager: FileManager)
    -> [AgentIntegration.Component]
  {
    let installer = CopilotHooksInstaller(
      homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
    return [
      AgentIntegration.Component(
        kind: .hooks,
        state: { installer.installState() },
        install: { try installer.install() },
        uninstall: { try installer.uninstall() }
      ),
      skillsComponent(agent: .copilot, homeDirectoryURL: homeDirectoryURL),
    ]
  }

  private static func skillsComponent(
    agent: SkillAgent, homeDirectoryURL: URL
  ) -> AgentIntegration.Component {
    let installer = CLISkillInstaller(homeDirectoryURL: homeDirectoryURL)
    return AgentIntegration.Component(
      kind: .skills,
      state: { installer.installState(agent) },
      install: { try installer.install(agent) },
      uninstall: { try installer.uninstall(agent) }
    )
  }
}
