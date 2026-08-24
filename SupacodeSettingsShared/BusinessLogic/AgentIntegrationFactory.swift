import Foundation

/// Builds an `AgentIntegration` for each agent by composing the existing
/// per-agent installers. The component list per agent is the canonical
/// definition of "what installing the integration means" for that agent.
nonisolated enum AgentIntegrationFactory {
  static func make(
    for agent: SkillAgent,
    homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
    configDirectoryURL: URL? = nil,
    fileManager: FileManager = .default
  ) -> AgentIntegration {
    // Only agents whose whole integration lives under one relocatable config dir
    // honor a custom override; the rest stay home-rooted.
    let defaultConfigDir = homeDirectoryURL.appending(
      path: agent.configDirectoryName, directoryHint: .isDirectory)
    let resolvedConfigDir =
      agent.supportsCustomConfigFolder ? (configDirectoryURL ?? defaultConfigDir) : defaultConfigDir

    let components =
      switch agent {
      case .antigravity:
        antigravity(
          homeDirectoryURL: homeDirectoryURL, configDirectoryURL: resolvedConfigDir, fileManager: fileManager)
      case .claude: claude(configDirectoryURL: resolvedConfigDir, fileManager: fileManager)
      case .codex: codex(configDirectoryURL: resolvedConfigDir, fileManager: fileManager)
      case .copilot: copilot(configDirectoryURL: resolvedConfigDir, fileManager: fileManager)
      case .grok: grok(configDirectoryURL: resolvedConfigDir, fileManager: fileManager)
      case .hermes: hermes(configDirectoryURL: resolvedConfigDir, fileManager: fileManager)
      case .kimi: kimi(configDirectoryURL: resolvedConfigDir, fileManager: fileManager)
      case .kiro: kiro(configDirectoryURL: resolvedConfigDir, fileManager: fileManager)
      case .omp: omp(configDirectoryURL: resolvedConfigDir, fileManager: fileManager)
      case .pi: pi(configDirectoryURL: resolvedConfigDir, fileManager: fileManager)
      case .opencode: opencode(configDirectoryURL: resolvedConfigDir, fileManager: fileManager)
      }
    // Gate install on the resolved config directory existing, as a proxy for the
    // CLI being installed, so Supacode never bootstraps a harness from nothing. A
    // custom folder the user picked already exists, satisfying the gate.
    return AgentIntegration(
      agent: agent,
      components: components,
      requiredDirectory: resolvedConfigDir,
      fileManager: fileManager
    )
  }

  // MARK: - Per-agent component lists.

  private static func antigravity(homeDirectoryURL: URL, configDirectoryURL: URL, fileManager: FileManager)
    -> [AgentIntegration.Component]
  {
    let installer = AntigravitySettingsInstaller(
      homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
    return [
      AgentIntegration.Component(
        kind: .hooks,
        state: { try installer.installState() },
        install: { try installer.installAllHooks() },
        uninstall: { try installer.uninstallAllHooks() }
      ),
      skillsComponent(agent: .antigravity, configDirectoryURL: configDirectoryURL),
    ]
  }

  private static func claude(configDirectoryURL: URL, fileManager: FileManager)
    -> [AgentIntegration.Component]
  {
    let installer = ClaudeSettingsInstaller(
      configDirectoryURL: configDirectoryURL, fileManager: fileManager)
    return [
      AgentIntegration.Component(
        kind: .hooks,
        state: { try installer.installState() },
        install: { try installer.installAllHooks() },
        uninstall: { try installer.uninstallAllHooks() }
      ),
      skillsComponent(agent: .claude, configDirectoryURL: configDirectoryURL),
    ]
  }

  private static func codex(configDirectoryURL: URL, fileManager: FileManager)
    -> [AgentIntegration.Component]
  {
    let installer = CodexSettingsInstaller(
      configDirectoryURL: configDirectoryURL, fileManager: fileManager)
    return [
      AgentIntegration.Component(
        kind: .hooks,
        state: { try installer.installState() },
        install: { try await installer.installAllHooks() },
        uninstall: { try installer.uninstallAllHooks() }
      ),
      skillsComponent(agent: .codex, configDirectoryURL: configDirectoryURL),
    ]
  }

  private static func grok(configDirectoryURL: URL, fileManager: FileManager)
    -> [AgentIntegration.Component]
  {
    let installer = GrokSettingsInstaller(
      configDirectoryURL: configDirectoryURL, fileManager: fileManager)
    return [
      AgentIntegration.Component(
        kind: .hooks,
        state: { try installer.installState() },
        install: { try installer.installAllHooks() },
        uninstall: { try installer.uninstallAllHooks() }
      ),
      skillsComponent(agent: .grok, configDirectoryURL: configDirectoryURL),
    ]
  }

  private static func kimi(configDirectoryURL: URL, fileManager: FileManager)
    -> [AgentIntegration.Component]
  {
    let installer = KimiSettingsInstaller(
      configDirectoryURL: configDirectoryURL, fileManager: fileManager)
    return [
      AgentIntegration.Component(
        kind: .hooks,
        state: { try installer.installState() },
        install: { try installer.installAllHooks() },
        uninstall: { try installer.uninstallAllHooks() }
      ),
      skillsComponent(agent: .kimi, configDirectoryURL: configDirectoryURL),
    ]
  }

  private static func hermes(configDirectoryURL: URL, fileManager: FileManager)
    -> [AgentIntegration.Component]
  {
    let installer = HermesPluginInstaller(
      configDirectoryURL: configDirectoryURL, fileManager: fileManager)
    return [
      AgentIntegration.Component(
        kind: .hooks,
        state: { try installer.installState() },
        install: { try installer.install() },
        uninstall: { try installer.uninstall() }
      ),
      skillsComponent(agent: .hermes, configDirectoryURL: configDirectoryURL),
    ]
  }

  private static func kiro(configDirectoryURL: URL, fileManager: FileManager)
    -> [AgentIntegration.Component]
  {
    let installer = KiroSettingsInstaller(
      configDirectoryURL: configDirectoryURL, fileManager: fileManager)
    return [
      AgentIntegration.Component(
        kind: .hooks,
        state: { try installer.installState() },
        install: { try await installer.installAllHooks() },
        uninstall: { try installer.uninstallAllHooks() }
      ),
      skillsComponent(agent: .kiro, configDirectoryURL: configDirectoryURL),
    ]
  }

  private static func omp(configDirectoryURL: URL, fileManager: FileManager)
    -> [AgentIntegration.Component]
  {
    let installer = OmpSettingsInstaller(
      configDirectoryURL: configDirectoryURL, fileManager: fileManager)
    return [
      AgentIntegration.Component(
        kind: .hooks,
        state: { try installer.installState() },
        install: { try installer.install() },
        uninstall: { try installer.uninstall() }
      ),
      skillsComponent(agent: .omp, configDirectoryURL: configDirectoryURL),
    ]
  }

  private static func pi(configDirectoryURL: URL, fileManager: FileManager)
    -> [AgentIntegration.Component]
  {
    let installer = PiSettingsInstaller(
      configDirectoryURL: configDirectoryURL, fileManager: fileManager)
    return [
      AgentIntegration.Component(
        kind: .hooks,
        state: { try installer.installState() },
        install: { try installer.install() },
        uninstall: { try installer.uninstall() }
      ),
      skillsComponent(agent: .pi, configDirectoryURL: configDirectoryURL),
    ]
  }

  private static func opencode(configDirectoryURL: URL, fileManager: FileManager)
    -> [AgentIntegration.Component]
  {
    let installer = OpenCodePluginInstaller(
      configDirectoryURL: configDirectoryURL, fileManager: fileManager)
    return [
      AgentIntegration.Component(
        kind: .hooks,
        state: { try installer.installState() },
        install: { try installer.install() },
        uninstall: { try installer.uninstall() }
      ),
      skillsComponent(agent: .opencode, configDirectoryURL: configDirectoryURL),
    ]
  }

  private static func copilot(configDirectoryURL: URL, fileManager: FileManager)
    -> [AgentIntegration.Component]
  {
    let installer = CopilotHooksInstaller(
      configDirectoryURL: configDirectoryURL, fileManager: fileManager)
    return [
      AgentIntegration.Component(
        kind: .hooks,
        state: { try installer.installState() },
        install: { try installer.install() },
        uninstall: { try installer.uninstall() }
      ),
      skillsComponent(agent: .copilot, configDirectoryURL: configDirectoryURL),
    ]
  }

  private static func skillsComponent(
    agent: SkillAgent, configDirectoryURL: URL
  ) -> AgentIntegration.Component {
    let installer = CLISkillInstaller(configDirectoryURL: configDirectoryURL)
    return AgentIntegration.Component(
      kind: .skills,
      state: { try installer.installState(agent) },
      install: { try installer.install(agent) },
      uninstall: { try installer.uninstall(agent) }
    )
  }
}
