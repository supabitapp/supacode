import Foundation

/// Builds an `AgentIntegration` for each agent by composing the existing
/// per-agent installers. The component list per agent is the canonical
/// definition of "what installing the integration means" for that agent.
public nonisolated enum AgentIntegrationFactory {
  public static func make(
    for agent: SkillAgent,
    homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
    fileManager: FileManager = .default
  ) -> AgentIntegration {
    switch agent {
    case .claude: claude(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
    case .codex: codex(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
    case .kiro: kiro(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
    case .pi: pi(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
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
          kind: .progressHooks,
          isInstalled: { installer.isInstalled(progress: true) },
          install: { try installer.installProgressHooks() },
          uninstall: { try installer.uninstallProgressHooks() }
        ),
        AgentIntegration.Component(
          kind: .notificationHooks,
          isInstalled: { installer.isInstalled(progress: false) },
          install: { try installer.installNotificationHooks() },
          uninstall: { try installer.uninstallNotificationHooks() }
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
          kind: .progressHooks,
          isInstalled: { installer.isInstalled(progress: true) },
          install: { try await installer.installProgressHooks() },
          uninstall: { try installer.uninstallProgressHooks() }
        ),
        AgentIntegration.Component(
          kind: .notificationHooks,
          isInstalled: { installer.isInstalled(progress: false) },
          install: { try await installer.installNotificationHooks() },
          uninstall: { try installer.uninstallNotificationHooks() }
        ),
        skillComponent(agent: .codex, installer: skill),
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
          kind: .progressHooks,
          isInstalled: { installer.isInstalled(progress: true) },
          install: { try await installer.installProgressHooks() },
          uninstall: { try installer.uninstallProgressHooks() }
        ),
        AgentIntegration.Component(
          kind: .notificationHooks,
          isInstalled: { installer.isInstalled(progress: false) },
          install: { try await installer.installNotificationHooks() },
          uninstall: { try installer.uninstallNotificationHooks() }
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
          isInstalled: { installer.isInstalled() },
          install: { try installer.install() },
          uninstall: { try installer.uninstall() }
        ),
        skillComponent(agent: .pi, installer: skill),
      ]
    )
  }

  private static func skillComponent(
    agent: SkillAgent, installer: CLISkillInstaller
  ) -> AgentIntegration.Component {
    AgentIntegration.Component(
      kind: .cliSkill,
      isInstalled: { installer.isInstalled(agent) },
      install: { try installer.install(agent) },
      uninstall: { try installer.uninstall(agent) }
    )
  }
}
