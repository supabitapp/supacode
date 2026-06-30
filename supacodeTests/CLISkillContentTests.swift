import Testing

@testable import SupacodeSettingsShared

@Suite
struct CLISkillContentTests {
  @Test func allShippedSkillVariantsDocumentDeepLinks() {
    for variant in Self.shippedSkillVariants {
      #expect(variant.content.contains("supacode://"), "\(variant.name) should document the supacode URL scheme.")
      #expect(variant.content.contains("## Deep links"), "\(variant.name) should include a Deep links section.")
    }
  }

  @Test func allShippedSkillVariantsDocumentWorktreeDeepLinkRoute() {
    for variant in Self.shippedSkillVariants {
      #expect(variant.content.contains("supacode://worktree"), "\(variant.name) should document worktree deep links.")
    }
  }

  private static let shippedSkillVariants: [(name: String, content: String)] = [
    ("claudeSkill", CLISkillContent.claudeSkill),
    ("codexSkillMd", CLISkillContent.codexSkillMd),
    ("codexAgentsMd", CLISkillContent.codexAgentsMd),
    ("kiroSkillMd", CLISkillContent.kiroSkillMd),
    ("kimiSkillMd", CLISkillContent.kimiSkillMd),
    ("piSkillMd", CLISkillContent.piSkillMd),
    ("opencodeSkillMd", CLISkillContent.opencodeSkillMd),
    ("copilotSkillMd", CLISkillContent.copilotSkillMd),
  ]
}
