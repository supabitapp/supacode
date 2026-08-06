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
