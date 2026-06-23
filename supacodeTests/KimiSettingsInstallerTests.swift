import Foundation
import Testing

@testable import SupacodeSettingsShared

struct KimiSettingsInstallerTests {
  private let fileManager = FileManager.default

  private func makeInstaller() -> KimiHookSettingsFileInstaller {
    KimiHookSettingsFileInstaller(fileManager: fileManager)
  }

  private func makeTempURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("supacode-kimi-test-\(UUID().uuidString)")
      .appendingPathComponent("config.toml")
  }

  private func canonicalEntries() -> [KimiHookEntry] {
    KimiHookSettings.canonicalEntries()
  }

  private func managedCommand(for event: String) throws -> String {
    let entries = canonicalEntries()
    return try #require(entries.first(where: { $0.event == event })?.command)
  }

  // MARK: - Fresh install.

  @Test func freshInstallWritesCanonicalEntries() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }

    let installer = makeInstaller()
    try installer.install(settingsURL: url, canonicalEntries: canonicalEntries())

    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("[[hooks]]"))
    #expect(text.contains("event = \"SessionStart\""))
    #expect(text.contains("event = \"Stop\""))
    #expect(try text.components(separatedBy: "[[hooks]]").count - 1 == canonicalEntries().count)
  }

  @Test func freshInstallStateIsNotInstalledWhenFileMissing() throws {
    let url = makeTempURL()
    let installer = makeInstaller()
    #expect(installer.installState(settingsURL: url, canonicalEntries: canonicalEntries()) == .notInstalled)
  }

  // MARK: - Preserve existing content.

  @Test func installPreservesNonHooksSections() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }
    try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let existing = """
      model = "kimi-k2"
      merge_all_available_skills = true

      [features]
      experimental = true
      """
    try existing.write(to: url, atomically: true, encoding: .utf8)

    let installer = makeInstaller()
    try installer.install(settingsURL: url, canonicalEntries: canonicalEntries())

    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("model = \"kimi-k2\""))
    #expect(text.contains("[features]"))
    #expect(text.contains("experimental = true"))
    #expect(text.contains("[[hooks]]"))
  }

  @Test func installPreservesUserAuthoredHooksBlocks() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }
    try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let existing = """
      [[hooks]]
      event = "PostToolUse"
      command = "prettier --write"
      matcher = "WriteFile"

      [other]
      key = "val"
      """
    try existing.write(to: url, atomically: true, encoding: .utf8)

    let installer = makeInstaller()
    try installer.install(settingsURL: url, canonicalEntries: canonicalEntries())

    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("prettier --write"))
    let hookBlocks = text.components(separatedBy: "[[hooks]]")
    // +1 for the user block, +N for canonical, -1 because split drops the prefix.
    #expect(hookBlocks.count - 1 == canonicalEntries().count + 1)
  }

  @Test func installPreservesBlocksWithCommandLikeKeys() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }
    try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let existing = """
      [[hooks]]
      event = "PreToolUse"
      commander = "not-a-command"
      command_timeout = 30
      """
    try existing.write(to: url, atomically: true, encoding: .utf8)

    let installer = makeInstaller()
    try installer.install(settingsURL: url, canonicalEntries: canonicalEntries())

    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("commander"))
    #expect(text.contains("command_timeout"))
    let hookBlocks = text.components(separatedBy: "[[hooks]]")
    #expect(hookBlocks.count - 1 == canonicalEntries().count + 1)
  }

  // MARK: - Idempotent re-install.

  @Test func reinstallIsIdempotent() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }

    let installer = makeInstaller()
    let entries = canonicalEntries()
    try installer.install(settingsURL: url, canonicalEntries: entries)
    let firstPass = try String(contentsOf: url, encoding: .utf8)
    try installer.install(settingsURL: url, canonicalEntries: entries)
    let secondPass = try String(contentsOf: url, encoding: .utf8)

    #expect(firstPass == secondPass)
    #expect(installer.installState(settingsURL: url, canonicalEntries: entries) == .installed)
  }

  // MARK: - Uninstall.

  @Test func uninstallRemovesManagedBlocksAndKeepsUserBlocks() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }

    let installer = makeInstaller()
    let entries = canonicalEntries()
    try installer.install(settingsURL: url, canonicalEntries: entries)

    // Append a user-authored hook block directly.
    let userBlock = """

      [[hooks]]
      event = "PostToolUse"
      command = "user-formatter"
      matcher = "WriteFile"
      """
    let before = try String(contentsOf: url, encoding: .utf8)
    try (before + userBlock).write(to: url, atomically: true, encoding: .utf8)

    try installer.uninstall(settingsURL: url, canonicalEntries: entries)

    let after = try String(contentsOf: url, encoding: .utf8)
    #expect(after.contains("user-formatter"))
    #expect(!after.contains(AgentHookSettingsCommand.ownershipMarker))
    let hookBlocks = after.components(separatedBy: "[[hooks]]")
    #expect(hookBlocks.count - 1 == 1)  // Only the user block remains.
  }

  @Test func uninstallOnMissingFileIsNoOp() throws {
    let url = makeTempURL()
    let installer = makeInstaller()
    #expect(throws: Never.self) {
      try installer.uninstall(settingsURL: url, canonicalEntries: canonicalEntries())
    }
  }

  // MARK: - Outdated detection.

  @Test func installStateReportsOutdatedWhenSubsetPresent() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }
    try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    // Seed just one managed block (SessionStart) out of the full canonical set.
    let sessionStart = try managedCommand(for: "SessionStart")
    let partial = """
      [[hooks]]
      event = "SessionStart"
      command = "\(sessionStart)"
      timeout = 5
      """
    try partial.write(to: url, atomically: true, encoding: .utf8)

    let installer = makeInstaller()
    #expect(installer.installState(settingsURL: url, canonicalEntries: canonicalEntries()) == .outdated)
  }

  @Test func installStateReportsInstalledWhenSetMatches() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }

    let installer = makeInstaller()
    let entries = canonicalEntries()
    try installer.install(settingsURL: url, canonicalEntries: entries)
    #expect(installer.installState(settingsURL: url, canonicalEntries: entries) == .installed)
  }

  // MARK: - TOML block rendering.

  @Test func renderedBlockUsesArrayOfWeeksHeaderAndFlatFields() throws {
    let entry = KimiHookEntry(event: "Stop", command: "echo hi # supacode-managed-hook", timeout: 7)
    let block = KimiHookSettingsFileInstaller.renderBlock(entry)
    #expect(block.hasPrefix("[[hooks]]"))
    #expect(block.contains("event = \"Stop\""))
    #expect(block.contains("command = \"echo hi # supacode-managed-hook\""))
    #expect(block.contains("timeout = 7"))
    // No matcher line when matcher is empty.
    #expect(!block.contains("matcher"))
  }

  @Test func renderedBlockIncludesMatcherWhenNonEmpty() throws {
    let entry = KimiHookEntry(
      event: "PreToolUse", command: "echo # supacode-managed-hook",
      matcher: "WriteFile|StrReplace", timeout: 5, )
    let block = KimiHookSettingsFileInstaller.renderBlock(entry)
    #expect(block.contains("matcher = \"WriteFile|StrReplace\""))
  }

  @Test func tomlQuoteEscapesBackslashAndDoubleQuote() throws {
    let entry = KimiHookEntry(
      event: "Stop",
      command: #"printf 'a"b\c' # supacode-managed-hook"#,
      timeout: 5, )
    let block = KimiHookSettingsFileInstaller.renderBlock(entry)
    // Backslash and quote must be escaped so TOML parses back to the original.
    #expect(block.contains("command = \"printf 'a\\\"b\\\\c' # supacode-managed-hook\""))
  }

  @Test func managedCommandsRoundTripThroughRenderer() throws {
    // Every canonical command we emit must self-identify as Supacode-managed
    // after going through `renderBlock` (i.e. the sentinel survives quoting).
    let entries = canonicalEntries()
    for entry in entries {
      let block = KimiHookSettingsFileInstaller.renderBlock(entry)
      #expect(block.contains(AgentHookSettingsCommand.ownershipMarker))
    }
  }
}
