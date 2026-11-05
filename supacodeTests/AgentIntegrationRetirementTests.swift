import Foundation
import Testing

@testable import SupacodeSettingsShared

struct AgentIntegrationRetirementTests {
  // MARK: - State.

  @Test func leftoverRetiredComponentReadsOutdatedEvenWhenEverythingElseIsInstalled() throws {
    let integration = AgentIntegration(
      agent: .claude,
      components: [component(state: .installed)],
      retiredComponents: [component(state: .installed)]
    )
    #expect(try integration.state() == .outdated)
  }

  @Test func partlyLeftoverRetiredComponentReadsOutdated() throws {
    let integration = AgentIntegration(
      agent: .claude,
      components: [component(state: .installed)],
      retiredComponents: [component(state: .outdated)]
    )
    #expect(try integration.state() == .outdated)
  }

  @Test func leftoverRetiredComponentReadsOutdatedWhenNothingElseIsInstalled() throws {
    // Someone who had the hooks opted in, so the upgrade may finish the install.
    let integration = AgentIntegration(
      agent: .claude,
      components: [component(state: .notInstalled)],
      retiredComponents: [component(state: .installed)]
    )
    #expect(try integration.state() == .outdated)
  }

  @Test(arguments: [ComponentInstallState.installed, .notInstalled, .outdated])
  func absentRetiredComponentLeavesTheStateToTheComponents(_ state: ComponentInstallState) throws {
    let integration = AgentIntegration(
      agent: .claude,
      components: [component(state: state)],
      retiredComponents: [component(state: .notInstalled)]
    )
    let expected: AgentIntegrationState =
      switch state {
      case .installed: .installed
      case .notInstalled: .notInstalled
      case .outdated: .outdated
      }
    #expect(try integration.state() == expected)
  }

  @Test func unreadableRetiredComponentThrowsRatherThanArmingARewrite() {
    let integration = AgentIntegration(
      agent: .claude,
      components: [component(state: .installed)],
      retiredComponents: [
        AgentIntegration.Component(
          kind: .hooks,
          state: { throw AgentFileUnreadableError(displayPath: "~/.claude/settings.json", reason: "nope") },
          install: {},
          uninstall: {}
        )
      ]
    )
    #expect(throws: AgentFileUnreadableError.self) { try integration.state() }
  }

  // MARK: - Install and uninstall.

  @Test func installRemovesRetiredComponentsAfterInstalling() async throws {
    let log = Log()
    let integration = AgentIntegration(
      agent: .claude,
      components: [recording("skills", log)],
      retiredComponents: [recording("old-hooks", log)]
    )

    try await integration.install()

    #expect(log.entries == ["install skills", "uninstall old-hooks"])
  }

  @Test func failedInstallKeepsTheRetiredComponentsSoTheUpgradeRetries() async throws {
    // The leftover is what reads `.outdated`; removing it before a failed install
    // would turn a retryable upgrade into a silent `.notInstalled`.
    let log = Log()
    let integration = AgentIntegration(
      agent: .claude,
      components: [
        AgentIntegration.Component(kind: .skills, state: { .notInstalled }, install: { throw Boom() }, uninstall: {})
      ],
      retiredComponents: [
        AgentIntegration.Component(
          kind: .hooks, state: { .installed }, install: {}, uninstall: { log.append("uninstall old-hooks") })
      ]
    )

    await #expect(throws: Boom.self) { try await integration.install() }
    #expect(log.entries.isEmpty)
    #expect(try integration.state() == .outdated)
  }

  @Test func failedRetirementLeavesTheIntegrationOutdated() async throws {
    let log = Log()
    let integration = AgentIntegration(
      agent: .claude,
      components: [recording("skills", log)],
      retiredComponents: [
        AgentIntegration.Component(kind: .hooks, state: { .installed }, install: {}, uninstall: { throw Boom() })
      ]
    )

    await #expect(throws: Boom.self) { try await integration.install() }
    #expect(log.entries == ["install skills"])
    #expect(try integration.state() == .outdated)
  }

  @Test func uninstallAlsoRemovesRetiredComponents() throws {
    let log = Log()
    let integration = AgentIntegration(
      agent: .claude,
      components: [recording("skills", log)],
      retiredComponents: [recording("old-hooks", log)]
    )

    try integration.uninstall()

    #expect(log.entries == ["uninstall skills", "uninstall old-hooks"])
  }

  @Test func uninstallKeepsSweepingWhenARetiredComponentFails() {
    let log = Log()
    let integration = AgentIntegration(
      agent: .claude,
      components: [recording("skills", log)],
      retiredComponents: [
        AgentIntegration.Component(kind: .hooks, state: { .installed }, install: {}, uninstall: { throw Boom() }),
        recording("old-plugin", log),
      ]
    )

    #expect(throws: Boom.self) { try integration.uninstall() }
    #expect(log.entries == ["uninstall skills", "uninstall old-plugin"])
  }

  // MARK: - Factory.

  @Test(arguments: SkillAgent.allCases)
  func programStatusAgentsRetireTheirHooksAndKeepTheirSkills(_ agent: SkillAgent) {
    let integration = AgentIntegrationFactory.make(for: agent, homeDirectoryURL: temporaryDirectory())

    if agent.programStatusApp != nil {
      #expect(integration.components.map(\.kind) == [.skills])
      #expect(integration.retiredComponents.map(\.kind) == [.hooks])
    } else {
      #expect(integration.components.map(\.kind) == [.hooks, .skills])
      #expect(integration.retiredComponents.isEmpty)
    }
  }

  @Test(arguments: SkillAgent.allCases.filter { $0.programStatusApp != nil })
  func freshMachineReadsNotInstalled(_ agent: SkillAgent) throws {
    let configDirectory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: configDirectory) }

    let integration = AgentIntegrationFactory.make(for: agent, configDirectoryURL: configDirectory)

    #expect(try integration.state() == .notInstalled)
  }

  // MARK: - Migration on real files.

  @Test func claudeMigrationRemovesOnlySupacodesHooks() async throws {
    let configDirectory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: configDirectory) }
    let settingsURL = configDirectory.appending(path: "settings.json")
    let userHook = #"{"type":"command","command":"say done"}"#
    try Data(#"{"model":"opus","hooks":{"Stop":[{"hooks":[\#(userHook)]}]}}"#.utf8).write(to: settingsURL)
    // What an older Supacode installed: the hooks plus the skills.
    let legacy = ClaudeSettingsInstaller(configDirectoryURL: configDirectory)
    try legacy.installAllHooks()
    try CLISkillInstaller(configDirectoryURL: configDirectory).install(.claude)
    #expect(try legacy.installState() == .installed)

    let integration = AgentIntegrationFactory.make(for: .claude, configDirectoryURL: configDirectory)
    #expect(try integration.state() == .outdated)

    try await integration.install()

    #expect(try integration.state() == .installed)
    #expect(try legacy.installState() == .notInstalled)
    let settings = try String(contentsOf: settingsURL, encoding: .utf8)
    #expect(settings.contains("say done"))
    #expect(settings.contains("opus"))
    #expect(!settings.contains("3008"))
    #expect(
      FileManager.default.fileExists(
        atPath: configDirectory.appending(path: "skills/supacode-cli/SKILL.md").path(percentEncoded: false)))
  }

  @Test func claudeMigrationIsIdempotent() async throws {
    let configDirectory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: configDirectory) }
    try ClaudeSettingsInstaller(configDirectoryURL: configDirectory).installAllHooks()
    let integration = AgentIntegrationFactory.make(for: .claude, configDirectoryURL: configDirectory)

    try await integration.install()
    let first = try Data(contentsOf: configDirectory.appending(path: "settings.json"))
    try await integration.install()

    #expect(try Data(contentsOf: configDirectory.appending(path: "settings.json")) == first)
    #expect(try integration.state() == .installed)
  }

  @Test func codexMigrationKeepsTheHooksFeatureFlag() async throws {
    let configDirectory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: configDirectory) }
    let legacy = CodexSettingsInstaller(
      configDirectoryURL: configDirectory,
      runEnableHooksCommand: { .init(status: 0, standardError: "") }
    )
    try await legacy.installAllHooks()
    let configURL = configDirectory.appending(path: "config.toml")
    try Data("model = \"gpt\"\n\n[features]\nhooks = true\n".utf8).write(to: configURL)
    #expect(try legacy.hookEntriesState() == .installed)

    let integration = AgentIntegrationFactory.make(for: .codex, configDirectoryURL: configDirectory)
    #expect(try integration.state() == .outdated)

    try await integration.install()

    #expect(try integration.state() == .installed)
    #expect(try legacy.hookEntriesState() == .notInstalled)
    let config = try String(contentsOf: configURL, encoding: .utf8)
    #expect(config.contains("hooks = true"))
    #expect(config.contains("model = \"gpt\""))
  }

  @Test(arguments: [SkillAgent.omp, .opencode, .pi])
  func pluginMigrationRemovesTheOldPlugin(_ agent: SkillAgent) async throws {
    let configDirectory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: configDirectory) }
    let legacyState: () throws -> ComponentInstallState
    switch agent {
    case .omp:
      let legacy = OmpSettingsInstaller(configDirectoryURL: configDirectory)
      try legacy.install()
      legacyState = legacy.installState
    case .opencode:
      let legacy = OpenCodePluginInstaller(configDirectoryURL: configDirectory)
      try legacy.install()
      legacyState = legacy.installState
    default:
      let legacy = PiSettingsInstaller(configDirectoryURL: configDirectory)
      try legacy.install()
      legacyState = legacy.installState
    }
    #expect(try legacyState() == .installed)

    let integration = AgentIntegrationFactory.make(for: agent, configDirectoryURL: configDirectory)
    #expect(try integration.state() == .outdated)

    try await integration.install()

    #expect(try legacyState() == .notInstalled)
    #expect(try integration.state() == .installed)
  }

  @Test func uninstallingAMigratedAgentAlsoClearsLeftoverHooks() throws {
    let configDirectory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: configDirectory) }
    let legacy = ClaudeSettingsInstaller(configDirectoryURL: configDirectory)
    try legacy.installAllHooks()
    let integration = AgentIntegrationFactory.make(for: .claude, configDirectoryURL: configDirectory)

    try integration.uninstall()

    #expect(try legacy.installState() == .notInstalled)
    #expect(try integration.state() == .notInstalled)
  }

  // MARK: - Helpers.

  private func component(state: ComponentInstallState) -> AgentIntegration.Component {
    AgentIntegration.Component(kind: .hooks, state: { state }, install: {}, uninstall: {})
  }

  private func recording(_ label: String, _ log: Log) -> AgentIntegration.Component {
    AgentIntegration.Component(
      kind: .hooks,
      state: { .notInstalled },
      install: { log.append("install \(label)") },
      uninstall: { log.append("uninstall \(label)") }
    )
  }

  private func temporaryDirectory() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "supacode-retire-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  private func makeDirectory() throws -> URL {
    let url = temporaryDirectory()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}

private struct Boom: Error {}

private final class Log: @unchecked Sendable {
  private let lock = NSLock()
  private var _entries: [String] = []

  var entries: [String] { lock.withLock { _entries } }

  nonisolated deinit {}

  func append(_ entry: String) { lock.withLock { _entries.append(entry) } }
}
