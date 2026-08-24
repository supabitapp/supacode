import Foundation
import Testing

@testable import SupacodeSettingsShared

struct SkillAgentTests {
  @Test func allCasesStayAlphabeticalByRawValue() {
    let raws = SkillAgent.allCases.map(\.rawValue)
    #expect(raws == raws.sorted())
  }

  @Test func allCasesByDisplayNameOrdersBySettingsLabel() {
    #expect(
      SkillAgent.allCasesByDisplayName.map(\.displayName) == [
        "Claude Code", "Codex", "Copilot CLI", "Google Antigravity", "Grok Code", "Hermes",
        "Kimi Code", "Kiro CLI", "Oh My Pi", "OpenCode", "Pi",
      ]
    )
  }

  @Test func antigravityIdentityUsesExpectedDisplayAndAssetNames() {
    #expect(SkillAgent.antigravity.rawValue == "antigravity")
    #expect(SkillAgent.antigravity.displayName == "Google Antigravity")
    #expect(SkillAgent.antigravity.assetName == "antigravity-mark")
    #expect(SkillAgent.antigravity.configDirectoryName == ".gemini/antigravity-cli")
  }

  @Test func hermesIdentityUsesExpectedDisplayAndAssetNames() {
    #expect(SkillAgent.hermes.rawValue == "hermes")
    #expect(SkillAgent.hermes.displayName == "Hermes")
    #expect(SkillAgent.hermes.assetName == "hermes-mark")
    #expect(SkillAgent.hermes.configDirectoryName == ".hermes")
  }

  @Test func kimiIdentityUsesKimiCodePathsAndDisplayName() {
    #expect(SkillAgent.kimi.rawValue == "kimi")
    #expect(SkillAgent.kimi.displayName == "Kimi Code")
    #expect(SkillAgent.kimi.configDirectoryName == ".kimi-code")
    #expect(SkillAgent.kimi.assetName == "kimi-mark")
  }

  @Test func selectedExistingAgentMappingsStayStable() {
    #expect(SkillAgent.claude.assetName == "claude-code-mark")
    #expect(SkillAgent.opencode.configDirectoryName == ".config/opencode")
    #expect(SkillAgent.pi.displayName == "Pi")
    #expect(SkillAgent.grok.displayName == "Grok Code")
    #expect(SkillAgent.kiro.displayName == "Kiro CLI")
  }

  @Test func nonRelocatableAgentsDisallowCustomConfigFolder() {
    // Antigravity spans two fixed subtrees; Kiro embeds absolute `~/.kiro` paths.
    let nonRelocatable: Set<SkillAgent> = [.antigravity, .kiro]
    for agent in SkillAgent.allCases {
      #expect(agent.supportsCustomConfigFolder == !nonRelocatable.contains(agent))
    }
  }

  @Test func capabilityGridMatchesInstalledHookEvents() {
    // Constant across every agent.
    for agent in SkillAgent.allCases {
      #expect(agent.supports(.activityBadge))
      #expect(agent.supports(.idleBadge))
      #expect(agent.supports(.skills))
    }
    // Varying rows, authored from each agent's installed hook events.
    #expect(
      SkillAgent.allCases.filter { $0.supports(.inputNeededBadge) }
        == [.claude, .copilot, .grok, .kimi, .opencode])
    #expect(SkillAgent.allCases.filter { $0.supports(.errorDetection) } == [.antigravity, .claude])
    #expect(SkillAgent.allCases.filter { $0.supports(.compactionBadge) } == [.claude])
    #expect(SkillAgent.allCases.filter { !$0.supports(.notifications) } == [.opencode])
    #expect(SkillAgent.allCases.filter { !$0.supports(.customFolder) } == [.antigravity, .kiro])
  }

  @Test func agentsFileDecodesLenientlyDroppingUnknownAgents() throws {
    // A missing key decodes to an empty file (old / fresh installs).
    #expect(try JSONDecoder().decode(AgentsFile.self, from: Data("{}".utf8)).agents.isEmpty)
    // An unknown agent drops only its own record; a nil path is the default dir.
    let json = #"{"agents":[{"agent":"claude","path":"~/.claude-gn"},{"agent":"bogus"},{"agent":"codex"}]}"#
    let file = try JSONDecoder().decode(AgentsFile.self, from: Data(json.utf8))
    #expect(
      file.agents == [
        AgentInstallRecord(agent: .claude, path: "~/.claude-gn"),
        AgentInstallRecord(agent: .codex, path: nil),
      ])
  }

  @Test func agentsFileDropsOnlyStructurallyMalformedRecordsKeepingSiblings() throws {
    // A wrong-typed or key-missing record must drop only itself, never wipe the
    // whole file: those records are the sole on-disk trace of custom folders.
    let json = #"""
      {"agents":[{"agent":"claude"},{"agent":42},{"path":"~/x"},{"agent":"codex","path":"~/.codex-gn"}]}
      """#
    let file = try JSONDecoder().decode(AgentsFile.self, from: Data(json.utf8))
    #expect(
      file.agents == [
        AgentInstallRecord(agent: .claude, path: nil),
        AgentInstallRecord(agent: .codex, path: "~/.codex-gn"),
      ])
    // A file that isn't an array of records at all resets to empty, not a crash.
    #expect(try JSONDecoder().decode(AgentsFile.self, from: Data(#"{"agents":7}"#.utf8)).agents.isEmpty)
  }

  @Test func agentsFileRoundTripsAndRecordTargetMappingIsSymmetric() throws {
    let file = AgentsFile(agents: [
      AgentInstallRecord(agent: .claude, path: nil),
      AgentInstallRecord(agent: .codex, path: "~/.codex-gn"),
    ])
    let decoded = try JSONDecoder().decode(AgentsFile.self, from: JSONEncoder().encode(file))
    #expect(decoded == file)
    // The record <-> target bridge round-trips for both location kinds.
    for record in file.agents {
      #expect(record.target.installRecord == record)
    }
    #expect(AgentInstallRecord(agent: .claude, path: nil).target == .standard(.claude))
    #expect(
      AgentInstallRecord(agent: .codex, path: "~/.codex-gn").target
        == AgentInstallTarget(agent: .codex, location: .custom(configDirectoryPath: "~/.codex-gn")))
  }

  @Test func integrationFactoryReturnsHermesIntegration() async throws {
    let home = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "supacode-hermes-agent-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: home) }

    let integration = AgentIntegrationFactory.make(for: .hermes, homeDirectoryURL: home)

    #expect(integration.agent == .hermes)
    #expect(try integration.state() == .notInstalled)
    // The install gate requires the agent's own config directory to exist.
    try FileManager.default.createDirectory(
      at: home.appending(path: SkillAgent.hermes.configDirectoryName), withIntermediateDirectories: true)
    try await integration.install()
    #expect(try integration.state() == .installed)
    #expect(
      FileManager.default.fileExists(
        atPath: home.appending(path: ".hermes/plugins/supacode-presence/plugin.yaml").path(percentEncoded: false)
      )
    )
    #expect(
      FileManager.default.fileExists(
        atPath: home.appending(path: ".hermes/plugins/supacode-presence/__init__.py").path(percentEncoded: false)
      )
    )
    #expect(
      FileManager.default.fileExists(
        atPath: home.appending(path: ".hermes/skills/supacode-cli/SKILL.md").path(percentEncoded: false)
      )
    )
  }

  @Test func relocatableAgentsInstallDirectlyIntoCustomConfigDir() async throws {
    // Every relocatable agent whose install is pure file I/O (no CLI subprocess).
    let agents: [SkillAgent] = [.claude, .copilot, .grok, .hermes, .kimi, .omp, .pi, .opencode]
    for agent in agents {
      let custom = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "supacode-custom-\(agent.rawValue)-\(UUID().uuidString)", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: custom) }

      let integration = AgentIntegrationFactory.make(for: agent, configDirectoryURL: custom)
      try await integration.install()

      #expect(try integration.state() == .installed, "\(agent.rawValue) should install into the custom dir")
      // Skills land at `<configDir>/skills`, uniform across agents: proves the
      // custom dir IS the config dir, not a home the dir-name is appended to.
      let skill = custom.appending(path: "skills/supacode-cli/SKILL.md").path(percentEncoded: false)
      #expect(FileManager.default.fileExists(atPath: skill), "\(agent.rawValue) skills in the custom dir")
      let nested =
        custom
        .appending(path: "\(agent.configDirectoryName)/skills/supacode-cli/SKILL.md").path(percentEncoded: false)
      #expect(!FileManager.default.fileExists(atPath: nested), "\(agent.rawValue) not nested under its dir name")
    }
  }

  @Test func codexInstallerWritesHooksIntoCustomConfigDir() async throws {
    let custom = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "supacode-custom-codex-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: custom) }

    // Stub the `codex features enable hooks` subprocess so the test doesn't shell out.
    let installer = CodexSettingsInstaller(
      configDirectoryURL: custom,
      runEnableHooksCommand: { .init(status: 0, standardError: "") }
    )
    try await installer.installAllHooks()

    // The hooks file lands in the custom dir. (Full `.installed` state also needs
    // the `[features] hooks = true` flag the real `codex` CLI writes, which the
    // stub doesn't, so assert the file placement that Step 2 actually threads.)
    #expect(
      FileManager.default.fileExists(
        atPath: custom.appending(path: "hooks.json").path(percentEncoded: false)),
      "Codex hooks land directly under the custom config dir")
  }

  @Test func antigravityIgnoresCustomConfigDirectoryOverride() async throws {
    let home = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "supacode-antigravity-home-\(UUID().uuidString)", directoryHint: .isDirectory)
    let custom = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "supacode-antigravity-custom-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: home) }
    defer { try? FileManager.default.removeItem(at: custom) }
    try FileManager.default.createDirectory(
      at: home.appending(path: SkillAgent.antigravity.configDirectoryName), withIntermediateDirectories: true)

    // Antigravity spans two fixed subtrees under home; the override is ignored.
    let integration = AgentIntegrationFactory.make(
      for: .antigravity, homeDirectoryURL: home, configDirectoryURL: custom)
    try await integration.install()

    #expect(try integration.state() == .installed)
    #expect(
      FileManager.default.fileExists(
        atPath: home.appending(path: ".gemini/config/hooks.json").path(percentEncoded: false)))
    #expect(
      !FileManager.default.fileExists(
        atPath: custom.appending(path: "config/hooks.json").path(percentEncoded: false)),
      "the custom dir must be ignored for antigravity")
    #expect(
      !FileManager.default.fileExists(
        atPath: custom.appending(path: "skills/supacode-cli/SKILL.md").path(percentEncoded: false)),
      "antigravity skills stay under its home config dir")
  }

  @Test func factoryBuiltIntegrationRefusesInstallWhenConfigDirAbsent() async throws {
    let home = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "supacode-nogate-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: home) }

    // The factory must wire `requiredDirectory` to the agent's config dir, so a
    // genuinely not-installed agent refuses install end-to-end.
    let integration = AgentIntegrationFactory.make(for: .hermes, homeDirectoryURL: home)
    await #expect(throws: AgentIntegrationError.notInstalled(.hermes)) {
      try await integration.install()
    }
  }

  @Test func integrationFactoryReturnsAntigravityIntegration() async throws {
    let home = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "supacode-antigravity-agent-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: home) }

    let integration = AgentIntegrationFactory.make(for: .antigravity, homeDirectoryURL: home)

    #expect(integration.agent == .antigravity)
    #expect(try integration.state() == .notInstalled)
    // The install gate requires the agent's own config directory to exist.
    try FileManager.default.createDirectory(
      at: home.appending(path: SkillAgent.antigravity.configDirectoryName), withIntermediateDirectories: true)
    try await integration.install()
    #expect(try integration.state() == .installed)
    #expect(
      FileManager.default.fileExists(
        atPath: home.appending(path: ".gemini/config/hooks.json").path(percentEncoded: false)
      )
    )
    #expect(
      FileManager.default.fileExists(
        atPath: home.appending(path: ".gemini/antigravity-cli/settings.json").path(percentEncoded: false)
      )
    )
    #expect(
      FileManager.default.fileExists(
        atPath: home.appending(path: ".gemini/antigravity-cli/skills/supacode-cli/SKILL.md").path(percentEncoded: false)
      )
    )
  }
}
