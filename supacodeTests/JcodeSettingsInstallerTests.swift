import Foundation
import Testing

@testable import SupacodeSettingsShared

struct JcodeSettingsInstallerTests {
  private let fileManager = FileManager.default
  private let marker = AgentHookSettingsCommand.ownershipMarker

  private func makeTempHome() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("supacode-jcode-test-\(UUID().uuidString)", isDirectory: true)
  }

  private func makeInstaller(home: URL) -> JcodeSettingsInstaller {
    JcodeSettingsInstaller(homeDirectoryURL: home, fileManager: fileManager)
  }

  private func seed(_ text: String, at url: URL) throws {
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  // MARK: - Fresh install.

  @Test func freshInstallWritesHooksTableAndExecutableWrapper() throws {
    let home = makeTempHome()
    defer { try? fileManager.removeItem(at: home) }
    let installer = makeInstaller(home: home)

    try installer.installAllHooks()

    let config = try String(contentsOf: installer.settingsURL, encoding: .utf8)
    #expect(config.contains("[hooks]"))
    for event in JcodeHookSettings.hookedEvents {
      #expect(config.contains("\(event) = "))
    }
    let wrapperPath = installer.wrapperURL.path(percentEncoded: false)
    #expect(config.contains(wrapperPath))
    #expect(config.contains(marker))

    // Wrapper exists, is our script, and is user-executable.
    let wrapper = try String(contentsOf: installer.wrapperURL, encoding: .utf8)
    #expect(wrapper.hasPrefix("#!/bin/sh"))
    #expect(wrapper.contains(marker))
    #expect(wrapper.contains(AgentPresenceOSC.surfaceEnvVar))  // the no-op-outside-Supacode guard
    #expect(wrapper.contains("JCODE_HOOK_EVENT"))
    let perms =
      try fileManager.attributesOfItem(
        atPath: wrapperPath)[.posixPermissions] as? NSNumber
    #expect((perms?.int16Value ?? 0) & 0o111 != 0)
  }

  @Test func freshStateIsNotInstalledWhenNothingPresent() throws {
    let home = makeTempHome()
    defer { try? fileManager.removeItem(at: home) }
    #expect(try makeInstaller(home: home).installState() == .notInstalled)
  }

  @Test func stateIsInstalledAfterInstall() throws {
    let home = makeTempHome()
    defer { try? fileManager.removeItem(at: home) }
    let installer = makeInstaller(home: home)
    try installer.installAllHooks()
    #expect(try installer.installState() == .installed)
  }

  // MARK: - Canonical paths.

  @Test func settingsAndWrapperURLsResolveUnderDotJcode() {
    let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
    #expect(
      JcodeSettingsInstaller.settingsURL(homeDirectoryURL: home).path(percentEncoded: false)
        == "/Users/test/.jcode/config.toml")
    #expect(
      JcodeHookSettings.wrapperURL(homeDirectoryURL: home).path(percentEncoded: false)
        == "/Users/test/.jcode/hooks/supacode-presence.sh")
  }

  // MARK: - Preserve existing content.

  @Test func installPreservesNonHooksSections() throws {
    let home = makeTempHome()
    defer { try? fileManager.removeItem(at: home) }
    let installer = makeInstaller(home: home)
    try seed(
      """
      model = "kimi-k2"

      [providers.openai]
      base_url = "https://example.com"
      """, at: installer.settingsURL)

    try installer.installAllHooks()

    let config = try String(contentsOf: installer.settingsURL, encoding: .utf8)
    #expect(config.contains("model = \"kimi-k2\""))
    #expect(config.contains("[providers.openai]"))
    #expect(config.contains("base_url = \"https://example.com\""))
    #expect(config.contains("[hooks]"))
    #expect(try installer.installState() == .installed)
  }

  @Test func installMergesWithAUserHookOnTheSameEventAsAnArray() throws {
    let home = makeTempHome()
    defer { try? fileManager.removeItem(at: home) }
    let installer = makeInstaller(home: home)
    try seed(
      """
      [hooks]
      turn_start = "my-own-hook"
      """, at: installer.settingsURL)

    try installer.installAllHooks()

    let config = try String(contentsOf: installer.settingsURL, encoding: .utf8)
    // The user's hook survives, now alongside ours in an array value.
    let wrapperPath = installer.wrapperURL.path(percentEncoded: false)
    let turnStartLine = try #require(
      config.components(separatedBy: "\n").first { $0.hasPrefix("turn_start = ") })
    let values = JcodeSettingsInstaller.quotedStrings(in: turnStartLine)
    #expect(values.contains("my-own-hook"))
    #expect(values.contains(wrapperPath))
    #expect(try installer.installState() == .installed)
  }

  // MARK: - Idempotency.

  @Test func reinstallIsIdempotent() throws {
    let home = makeTempHome()
    defer { try? fileManager.removeItem(at: home) }
    let installer = makeInstaller(home: home)

    try installer.installAllHooks()
    let first = try String(contentsOf: installer.settingsURL, encoding: .utf8)
    try installer.installAllHooks()
    let second = try String(contentsOf: installer.settingsURL, encoding: .utf8)

    #expect(first == second)
    // Exactly one entry per hooked event (no duplicates).
    for event in JcodeHookSettings.hookedEvents {
      #expect(second.components(separatedBy: "\(event) = ").count - 1 == 1)
    }
  }

  // MARK: - Uninstall.

  @Test func uninstallRemovesManagedEntriesAndWrapperButKeepsUserHooks() throws {
    let home = makeTempHome()
    defer { try? fileManager.removeItem(at: home) }
    let installer = makeInstaller(home: home)
    try seed(
      """
      [hooks]
      turn_start = "my-own-hook"

      [providers.openai]
      base_url = "https://example.com"
      """, at: installer.settingsURL)

    try installer.installAllHooks()
    #expect(fileManager.fileExists(atPath: installer.wrapperURL.path(percentEncoded: false)))

    try installer.uninstallAllHooks()

    let config = try String(contentsOf: installer.settingsURL, encoding: .utf8)
    #expect(!config.contains(marker))
    #expect(!config.contains(installer.wrapperURL.path(percentEncoded: false)))
    // The user's own hook and unrelated sections survive.
    #expect(config.contains("my-own-hook"))
    #expect(config.contains("[providers.openai]"))
    // The wrapper file is gone.
    #expect(!fileManager.fileExists(atPath: installer.wrapperURL.path(percentEncoded: false)))
    #expect(try installer.installState() == .notInstalled)
  }

  @Test func uninstallOnMissingFilesIsNoOp() throws {
    let home = makeTempHome()
    defer { try? fileManager.removeItem(at: home) }
    #expect(throws: Never.self) { try makeInstaller(home: home).uninstallAllHooks() }
  }

  @Test func uninstallKeepsAnUnmarkedUserFileSharingTheWrapperName() throws {
    let home = makeTempHome()
    defer { try? fileManager.removeItem(at: home) }
    let installer = makeInstaller(home: home)
    // A user file living at the wrapper path but lacking the ownership marker
    // must never be deleted by uninstall — only Supacode's own wrapper is removed.
    let userScript = "#!/bin/sh\necho hi\n"
    try seed(userScript, at: installer.wrapperURL)

    try installer.uninstallAllHooks()

    #expect(fileManager.fileExists(atPath: installer.wrapperURL.path(percentEncoded: false)))
    #expect(try String(contentsOf: installer.wrapperURL, encoding: .utf8) == userScript)
  }

  // MARK: - Outdated detection.

  @Test func stateIsOutdatedWhenWrapperBodyDrifts() throws {
    let home = makeTempHome()
    defer { try? fileManager.removeItem(at: home) }
    let installer = makeInstaller(home: home)
    try installer.installAllHooks()

    // A stale wrapper (e.g. from an older Supacode) must read as outdated so
    // auto-update repairs it — but only because the marker is still present.
    try "#!/bin/sh\n\(marker)\n# old body\n".write(
      to: installer.wrapperURL, atomically: true, encoding: .utf8)
    #expect(try installer.installState() == .outdated)
  }

  @Test func stateIsOutdatedWhenOnlySomeEventsPresent() throws {
    let home = makeTempHome()
    defer { try? fileManager.removeItem(at: home) }
    let installer = makeInstaller(home: home)
    let wrapperPath = installer.wrapperURL.path(percentEncoded: false)
    // Seed just one managed event out of the full set, plus a current wrapper.
    try seed(
      "[hooks]\n\(JcodeSettingsInstaller.render(event: "turn_start", values: [wrapperPath], managed: true))\n",
      at: installer.settingsURL)
    try seed(JcodeHookSettings.wrapperScript(), at: installer.wrapperURL)

    #expect(try installer.installState() == .outdated)
  }

  // MARK: - `[hooks]` value parsing.

  @Test func quotedStringsParsesStringArrayLiteralAndComment() {
    #expect(JcodeSettingsInstaller.quotedStrings(in: #""a""#) == ["a"])
    #expect(JcodeSettingsInstaller.quotedStrings(in: #"["a", "b"]"#) == ["a", "b"])
    #expect(JcodeSettingsInstaller.quotedStrings(in: #"'literal'"#) == ["literal"])
    #expect(
      JcodeSettingsInstaller.quotedStrings(in: #""cmd"  # supacode-managed-hook"#) == ["cmd"])
  }

  @Test func renderEmitsStringForOneValueAndArrayForMany() {
    #expect(
      JcodeSettingsInstaller.render(event: "turn_start", values: ["w"], managed: true)
        == "turn_start = \"w\"  \(marker)")
    #expect(
      JcodeSettingsInstaller.render(event: "turn_start", values: ["a", "w"], managed: false)
        == "turn_start = [\"a\", \"w\"]")
  }

  // MARK: - Line-ending tolerance & corrupt files.

  @Test func crlfConfigIsRecognizedAndNotDuplicatedOnReinstall() throws {
    let home = makeTempHome()
    defer { try? fileManager.removeItem(at: home) }
    let installer = makeInstaller(home: home)
    try installer.installAllHooks()

    let crlf = try String(contentsOf: installer.settingsURL, encoding: .utf8)
      .replacing("\n", with: "\r\n")
    try crlf.write(to: installer.settingsURL, atomically: true, encoding: .utf8)

    #expect(try installer.installState() == .installed)
    try installer.installAllHooks()
    let config = try String(contentsOf: installer.settingsURL, encoding: .utf8)
    for event in JcodeHookSettings.hookedEvents {
      #expect(config.components(separatedBy: "\(event) = ").count - 1 == 1)
    }
  }

  @Test func installStateThrowsOnInvalidUTF8() throws {
    let home = makeTempHome()
    defer { try? fileManager.removeItem(at: home) }
    let installer = makeInstaller(home: home)
    try fileManager.createDirectory(
      at: installer.settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data([0xFF, 0xFE, 0xFF]).write(to: installer.settingsURL)

    #expect(throws: JcodeSettingsInstallerError.invalidUTF8) {
      try installer.installState()
    }
  }

  // MARK: - Wrapper body.

  @Test func wrapperDispatchesEveryLifecycleEventToPresence() {
    let wrapper = JcodeHookSettings.wrapperScript()
    #expect(wrapper.contains("session_start)"))
    #expect(wrapper.contains("turn_start)"))
    #expect(wrapper.contains("turn_end)"))
    #expect(wrapper.contains("session_end)"))
    // The error branch keys off jcode's own status var.
    #expect(wrapper.contains("JCODE_HOOK_STATUS"))
    // Emits the shared OSC 3008 context signal (byte-identical to other harnesses).
    #expect(wrapper.contains("3008"))
    #expect(wrapper.contains("=jcode;"))
  }
}
