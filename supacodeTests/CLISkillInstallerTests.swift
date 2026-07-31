import Foundation
import Testing

@testable import SupacodeSettingsShared

final class CLISkillInstallerTests {
  private static let archiveWarningMarker = "Archiving or Deleting the Current Worktree"

  private let home = URL(fileURLWithPath: NSTemporaryDirectory())
    .appending(path: "supacode-skill-installer-\(UUID().uuidString)", directoryHint: .isDirectory)
  private let installer: CLISkillInstaller

  init() {
    installer = CLISkillInstaller(homeDirectoryURL: home)
  }

  deinit {
    try? FileManager.default.removeItem(at: home)
  }

  @Test func installWritesBothSkillFiles() throws {
    // The AGENTS.md prune is Codex-only; a stray sidecar elsewhere must survive.
    let strayAgentsMd = skillFile(.claude, "supacode-cli")
      .deletingLastPathComponent()
      .appending(path: "AGENTS.md", directoryHint: .notDirectory)
    try FileManager.default.createDirectory(
      at: strayAgentsMd.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "stray sidecar".write(to: strayAgentsMd, atomically: true, encoding: .utf8)

    try installer.install(.claude)

    #expect(FileManager.default.fileExists(atPath: skillFile(.claude, "supacode-cli").path))
    #expect(FileManager.default.fileExists(atPath: skillFile(.claude, "supacode-deeplinks").path))
    #expect(FileManager.default.fileExists(atPath: strayAgentsMd.path))
    #expect(installer.installState(.claude) == .installed)
  }

  @Test func uninstallIsIdempotent() throws {
    try installer.uninstall(.claude)

    try installer.install(.claude)
    try FileManager.default.removeItem(
      at: skillFile(.claude, "supacode-deeplinks").deletingLastPathComponent())
    try installer.uninstall(.claude)
    try installer.uninstall(.claude)

    #expect(installer.installState(.claude) == .notInstalled)
  }

  @Test func installPrunesLegacyCodexAgentsMd() throws {
    let legacyAgentsMd = skillFile(.codex, "supacode-cli")
      .deletingLastPathComponent()
      .appending(path: "AGENTS.md", directoryHint: .notDirectory)
    try FileManager.default.createDirectory(
      at: legacyAgentsMd.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "legacy sidecar".write(to: legacyAgentsMd, atomically: true, encoding: .utf8)
    #expect(installer.installState(.codex) == .notInstalled)

    try installer.install(.codex)

    #expect(!FileManager.default.fileExists(atPath: legacyAgentsMd.path))
    #expect(installer.installState(.codex) == .installed)
  }

  @Test func stateIsNotInstalledWhenNothingExists() {
    #expect(installer.installState(.claude) == .notInstalled)
  }

  @Test func stateIsOutdatedWhenDeeplinksSkillIsMissing() throws {
    try installer.install(.claude)
    try FileManager.default.removeItem(
      at: skillFile(.claude, "supacode-deeplinks").deletingLastPathComponent())

    #expect(installer.installState(.claude) == .outdated)
  }

  @Test func stateIsOutdatedWhenContentDrifts() throws {
    try installer.install(.claude)
    try "stale content".write(
      to: skillFile(.claude, "supacode-cli"), atomically: true, encoding: .utf8)
    #expect(installer.installState(.claude) == .outdated)

    try installer.install(.claude)
    #expect(installer.installState(.claude) == .installed)
  }

  @Test func uninstallRemovesBothSkillDirectories() throws {
    try installer.install(.claude)
    try installer.uninstall(.claude)

    #expect(!FileManager.default.fileExists(atPath: skillFile(.claude, "supacode-cli").path))
    #expect(!FileManager.default.fileExists(atPath: skillFile(.claude, "supacode-deeplinks").path))
    #expect(installer.installState(.claude) == .notInstalled)
  }

  @Test func cliSkillWarnsAboutArchiveAndDelete() throws {
    #expect(try CLISkillContent.cliSkill().contains(Self.archiveWarningMarker))
  }

  @Test func deeplinksSkillWarnsAboutArchiveAndDeleteAndPrefersCLI() throws {
    let content = try CLISkillContent.deeplinksSkill()
    #expect(content.contains(Self.archiveWarningMarker))
    #expect(content.contains("Always prefer the supacode CLI"))
  }

  // MARK: - Helpers.

  private func skillFile(_ agent: SkillAgent, _ skillName: String) -> URL {
    home.appending(
      path: "\(agent.configDirectoryName)/skills/\(skillName)/SKILL.md", directoryHint: .notDirectory)
  }
}
