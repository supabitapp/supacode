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
    // Render via `renderBlock` so the command is TOML-escaped; the canonical
    // command embeds double quotes that a raw basic string would not survive.
    let sessionStart = try #require(canonicalEntries().first(where: { $0.event == "SessionStart" }))
    let partial = KimiHookSettingsFileInstaller.renderBlock(sessionStart)
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

  @Test func renderedBlockUsesArrayOfTablesHeaderAndFlatFields() throws {
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

  // MARK: - Line-ending tolerance.

  @Test func crlfConfigIsDetectedAndNotDuplicatedOnReinstall() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }

    let installer = makeInstaller()
    let entries = canonicalEntries()
    try installer.install(settingsURL: url, canonicalEntries: entries)

    // Rewrite the freshly-installed file with CRLF line endings.
    let crlf = try String(contentsOf: url, encoding: .utf8).replacing("\n", with: "\r\n")
    try crlf.write(to: url, atomically: true, encoding: .utf8)

    // The managed blocks must still be recognized despite CRLF.
    #expect(installer.installState(settingsURL: url, canonicalEntries: entries) == .installed)

    // A reinstall must prune and replace, not append duplicates.
    try installer.install(settingsURL: url, canonicalEntries: entries)
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.components(separatedBy: "[[hooks]]").count - 1 == entries.count)
    #expect(installer.installState(settingsURL: url, canonicalEntries: entries) == .installed)
  }

  // MARK: - Section-header preservation.

  @Test func uninstallPreservesQuotedKeySectionAfterManagedBlock() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }

    let installer = makeInstaller()
    let entries = canonicalEntries()
    try installer.install(settingsURL: url, canonicalEntries: entries)

    // A quoted key with a space is valid TOML and must survive a prune.
    let userSection = """

      [mcp_servers."my server"]
      url = "http://localhost"
      """
    let before = try String(contentsOf: url, encoding: .utf8)
    try (before + userSection).write(to: url, atomically: true, encoding: .utf8)

    try installer.uninstall(settingsURL: url, canonicalEntries: entries)

    let after = try String(contentsOf: url, encoding: .utf8)
    #expect(after.contains("[mcp_servers.\"my server\"]"))
    #expect(after.contains("url = \"http://localhost\""))
    #expect(!after.contains(AgentHookSettingsCommand.ownershipMarker))
  }

  @Test func uninstallPreservesWhitespacePaddedSectionWithNoBlankSeparator() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }

    let installer = makeInstaller()
    let entries = canonicalEntries()
    try installer.install(settingsURL: url, canonicalEntries: entries)

    // Whitespace-padded header, immediately after the blocks with no blank line.
    let before = try String(contentsOf: url, encoding: .utf8)
    try (before + "[ other ]\nkey = \"val\"\n").write(to: url, atomically: true, encoding: .utf8)

    try installer.uninstall(settingsURL: url, canonicalEntries: entries)

    let after = try String(contentsOf: url, encoding: .utf8)
    #expect(after.contains("[ other ]"))
    #expect(after.contains("key = \"val\""))
    #expect(!after.contains(AgentHookSettingsCommand.ownershipMarker))
  }

  @Test func uninstallKeepsTrailingUserCommentAfterManagedBlock() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }

    let installer = makeInstaller()
    let entries = canonicalEntries()
    try installer.install(settingsURL: url, canonicalEntries: entries)

    let before = try String(contentsOf: url, encoding: .utf8)
    try (before + "# keep me\n[other]\nkey = \"val\"\n").write(to: url, atomically: true, encoding: .utf8)

    try installer.uninstall(settingsURL: url, canonicalEntries: entries)

    let after = try String(contentsOf: url, encoding: .utf8)
    #expect(after.contains("# keep me"))
    #expect(after.contains("[other]"))
    #expect(!after.contains(AgentHookSettingsCommand.ownershipMarker))
  }

  // MARK: - Command-string parsing.

  @Test func commandWithBackslashAndQuoteRoundTripsWithoutDuplication() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }

    let installer = makeInstaller()
    let command = #"printf 'a"b\c' "# + AgentHookSettingsCommand.ownershipMarker
    let entry = KimiHookEntry(event: "Stop", command: command, timeout: 5)

    try installer.install(settingsURL: url, canonicalEntries: [entry])
    #expect(installer.installState(settingsURL: url, canonicalEntries: [entry]) == .installed)

    // Re-detection after read-back must prune the prior block, not duplicate it.
    try installer.install(settingsURL: url, canonicalEntries: [entry])
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.components(separatedBy: "[[hooks]]").count - 1 == 1)
    #expect(installer.installState(settingsURL: url, canonicalEntries: [entry]) == .installed)
  }

  @Test func uninstallRemovesManagedBlockWrittenAsLiteralString() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }
    try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

    let marker = AgentHookSettingsCommand.ownershipMarker
    let literal = """
      [[hooks]]
      event = "Stop"
      command = 'echo hi \(marker)'
      timeout = 5
      """
    try literal.write(to: url, atomically: true, encoding: .utf8)

    let installer = makeInstaller()
    try installer.uninstall(settingsURL: url, canonicalEntries: canonicalEntries())

    let after = try String(contentsOf: url, encoding: .utf8)
    #expect(!after.contains(marker))
    #expect(!after.contains("[[hooks]]"))
  }

  // MARK: - Corrupt-file handling.

  @Test func installStateReportsNotInstalledAndLogsOnInvalidUTF8() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }
    try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data([0xFF, 0xFE, 0xFF]).write(to: url)

    let warnings = WarningBox()
    let installer = KimiHookSettingsFileInstaller(
      fileManager: fileManager, logWarning: { warnings.append($0) })

    #expect(installer.installState(settingsURL: url, canonicalEntries: canonicalEntries()) == .notInstalled)
    #expect(!warnings.messages.isEmpty)
    #expect(throws: KimiHookSettingsFileError.invalidUTF8) {
      try installer.install(settingsURL: url, canonicalEntries: canonicalEntries())
    }
  }

  @Test func invalidUTF8ErrorHasActionableDescription() {
    #expect(KimiHookSettingsFileError.invalidUTF8.errorDescription != nil)
  }

  // MARK: - Header-form tolerance.

  @Test func managedHeaderWithInteriorWhitespaceAndCommentIsRecognized() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }

    let installer = makeInstaller()
    let entries = canonicalEntries()
    try installer.install(settingsURL: url, canonicalEntries: entries)

    // A formatter or hand edit may pad the header and append a comment.
    let edited = try String(contentsOf: url, encoding: .utf8)
      .replacing("[[hooks]]", with: "[[ hooks ]]  # supacode")
    try edited.write(to: url, atomically: true, encoding: .utf8)

    #expect(installer.installState(settingsURL: url, canonicalEntries: entries) == .installed)

    // Reinstall must recognize and replace the padded headers, not duplicate.
    try installer.install(settingsURL: url, canonicalEntries: entries)
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.components(separatedBy: "[[hooks]]").count - 1 == entries.count)
    #expect(installer.installState(settingsURL: url, canonicalEntries: entries) == .installed)
  }

  @Test func crOnlyLineEndingsAreDetectedAndNotDuplicated() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }

    let installer = makeInstaller()
    let entries = canonicalEntries()
    try installer.install(settingsURL: url, canonicalEntries: entries)

    // Classic-Mac CR-only endings must normalize like CRLF.
    let crText = try String(contentsOf: url, encoding: .utf8).replacing("\n", with: "\r")
    try crText.write(to: url, atomically: true, encoding: .utf8)

    #expect(installer.installState(settingsURL: url, canonicalEntries: entries) == .installed)
    try installer.install(settingsURL: url, canonicalEntries: entries)
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.components(separatedBy: "[[hooks]]").count - 1 == entries.count)
  }

  @Test func sectionHeaderWithTrailingCommentIsPreserved() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }

    let installer = makeInstaller()
    let entries = canonicalEntries()
    try installer.install(settingsURL: url, canonicalEntries: entries)

    let before = try String(contentsOf: url, encoding: .utf8)
    try (before + "[other] # note\nkey = \"val\"\n").write(to: url, atomically: true, encoding: .utf8)

    try installer.uninstall(settingsURL: url, canonicalEntries: entries)

    let after = try String(contentsOf: url, encoding: .utf8)
    #expect(after.contains("[other] # note"))
    #expect(after.contains("key = \"val\""))
    #expect(!after.contains(AgentHookSettingsCommand.ownershipMarker))
  }

  @Test func trailingCommentSurvivesReinstallExactlyOnce() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }

    let installer = makeInstaller()
    let entries = canonicalEntries()
    try installer.install(settingsURL: url, canonicalEntries: entries)

    let before = try String(contentsOf: url, encoding: .utf8)
    try (before + "# keep me\n[other]\nkey = \"val\"\n").write(to: url, atomically: true, encoding: .utf8)

    try installer.uninstall(settingsURL: url, canonicalEntries: entries)
    try installer.install(settingsURL: url, canonicalEntries: entries)

    let after = try String(contentsOf: url, encoding: .utf8)
    #expect(after.components(separatedBy: "# keep me").count - 1 == 1)
    #expect(after.components(separatedBy: "[[hooks]]").count - 1 == entries.count)
  }
}

private nonisolated final class WarningBox: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [String] = []

  func append(_ message: String) {
    lock.lock()
    defer { lock.unlock() }
    stored.append(message)
  }

  var messages: [String] {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }
}
