import Foundation
import Testing

@testable import SupacodeSettingsShared

struct SkillAgentTests {
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
  }

  @Test func integrationFactoryReturnsHermesIntegration() async throws {
    let home = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "supacode-hermes-agent-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: home) }

    let integration = AgentIntegrationFactory.make(for: .hermes, homeDirectoryURL: home)

    #expect(integration.agent == .hermes)
    #expect(integration.state() == .notInstalled)
    try await integration.install()
    #expect(integration.state() == .installed)
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
}
