import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

struct CopilotHooksInstallerTests {
  private let fileManager = FileManager.default

  // MARK: - Ordering.

  /// `allCases` drives the agent order in Settings and the sidebar card, so it
  /// must stay alphabetical by raw value; a new case appended at the end regresses it.
  @Test func allCasesStayAlphabeticalByRawValue() {
    let raws = SkillAgent.allCases.map(\.rawValue)
    #expect(raws == raws.sorted())
  }

  private func makeTempHomeURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("supacode-copilot-hooks-\(UUID().uuidString)", isDirectory: true)
  }

  // MARK: - Install / uninstall.

  @Test func installWritesHookFileWhenMissing() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = CopilotHooksInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.install()

    #expect(fileManager.fileExists(atPath: installer.hookFileURL.path))
    let contents = try String(contentsOf: installer.hookFileURL, encoding: .utf8)
    #expect(try contents == CopilotHookSettings.source())
  }

  @Test func installIsIdempotent() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = CopilotHooksInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.install()
    let first = try Data(contentsOf: installer.hookFileURL)
    try installer.install()
    let second = try Data(contentsOf: installer.hookFileURL)

    #expect(first == second)
  }

  @Test func installThrowsForUnownedFileWithSameName() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = CopilotHooksInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try fileManager.createDirectory(
      at: installer.hookFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let userFile = #"{ "version": 1, "hooks": { "stop": [] } }"#
    try userFile.write(to: installer.hookFileURL, atomically: true, encoding: .utf8)

    #expect(throws: CopilotHooksInstallerError.fileNotManaged) {
      try installer.install()
    }
    let after = try String(contentsOf: installer.hookFileURL, encoding: .utf8)
    #expect(after == userFile)
  }

  @Test func uninstallRemovesOwnedFile() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = CopilotHooksInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.install()
    try installer.uninstall()

    #expect(!fileManager.fileExists(atPath: installer.hookFileURL.path))
    #expect(installer.installState() == .notInstalled)
  }

  @Test func uninstallThrowsForUnownedFileWithSameName() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = CopilotHooksInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try fileManager.createDirectory(
      at: installer.hookFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let userFile = #"{ "version": 1, "hooks": { "stop": [] } }"#
    try userFile.write(to: installer.hookFileURL, atomically: true, encoding: .utf8)

    #expect(throws: CopilotHooksInstallerError.fileNotManaged) {
      try installer.uninstall()
    }
    let after = try String(contentsOf: installer.hookFileURL, encoding: .utf8)
    #expect(after == userFile)
  }

  @Test func uninstallIsNoOpWhenMissing() {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = CopilotHooksInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    #expect(throws: Never.self) {
      try installer.uninstall()
    }
  }

  @Test func installAndUninstallPreserveSiblingUserHooks() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = CopilotHooksInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    let hooksDir = installer.hookFileURL.deletingLastPathComponent()
    try fileManager.createDirectory(at: hooksDir, withIntermediateDirectories: true)
    let siblingURL = hooksDir.appending(path: "my-hooks.json", directoryHint: .notDirectory)
    let sibling = #"{ "version": 1, "hooks": { "preToolUse": [] } }"#
    try sibling.write(to: siblingURL, atomically: true, encoding: .utf8)

    try installer.install()
    try installer.uninstall()

    #expect(!fileManager.fileExists(atPath: installer.hookFileURL.path))
    #expect(fileManager.fileExists(atPath: siblingURL.path))
    #expect(try String(contentsOf: siblingURL, encoding: .utf8) == sibling)
  }

  // MARK: - Install state.

  @Test func installStateNotInstalledBeforeInstall() {
    let homeURL = makeTempHomeURL()
    let installer = CopilotHooksInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    #expect(installer.installState() == .notInstalled)
  }

  @Test func installStateInstalledAfterInstall() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = CopilotHooksInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.install()
    #expect(installer.installState() == .installed)
  }

  @Test func installStateOutdatedWhenContentDiffers() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = CopilotHooksInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try fileManager.createDirectory(
      at: installer.hookFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    // A stale Supacode file: carries the ownership marker but differs.
    try #"{ "hooks": { "stop": [ { "bash": "old \#(CopilotHookSettings.ownershipMarker)" } ] } }"#
      .write(to: installer.hookFileURL, atomically: true, encoding: .utf8)

    #expect(installer.installState() == .outdated)
  }

  @Test func installStateNotInstalledForUnownedFileWithSameName() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = CopilotHooksInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try fileManager.createDirectory(
      at: installer.hookFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    // Unowned file must report `.notInstalled`, not `.outdated` (auto-update would overwrite it).
    try #"{ "version": 1, "hooks": { "stop": [] } }"#
      .write(to: installer.hookFileURL, atomically: true, encoding: .utf8)

    #expect(installer.installState() == .notInstalled)
  }

  @Test func hookFilePointsToExpectedPath() {
    let homeURL = URL(fileURLWithPath: "/Users/test")
    let installer = CopilotHooksInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    #expect(installer.hookFileURL.path == "/Users/test/.copilot/hooks/supacode.json")
  }

  // MARK: - Generated source.

  @Test func sourceIsValidJSONWithVersionAndEvents() throws {
    let data = Data(try CopilotHookSettings.source().utf8)
    let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(root["version"] as? Int == 1)
    let hooks = try #require(root["hooks"] as? [String: Any])
    #expect(
      Set(hooks.keys) == [
        "sessionStart", "userPromptSubmitted", "preToolUse", "postToolUse",
        "agentStop", "sessionEnd", "notification",
      ])
  }

  @Test func sourceCarriesOwnershipMarker() throws {
    #expect(try CopilotHookSettings.source().contains(CopilotHookSettings.ownershipMarker))
  }

  @Test func sourceEmbedsCopilotScopedOSCForEveryState() throws {
    let source = try CopilotHookSettings.source()
    #expect(source.contains("start=copilot;event=session_start"))
    #expect(source.contains("start=copilot;event=busy"))
    #expect(source.contains("start=copilot;event=idle"))
    #expect(source.contains("end=copilot;event=session_end"))
  }

  @Test func sourceForwardsNotificationsAndFlagsAwaitingInput() throws {
    let source = try CopilotHookSettings.source()
    #expect(source.contains("kind=notify"))
    #expect(source.contains("start=copilot;event=awaiting_input"))
    #expect(source.contains("permission_prompt"))
    #expect(source.contains("elicitation_dialog"))
  }

  /// Guards the hand-composed notification shell: the awaiting-input + notify
  /// legs must stay gated behind the permission / elicitation `case` branch so
  /// other notification types stay no-ops (a widened glob would alert on every
  /// notification).
  @Test func notificationCommandGatesAwaitingInputBehindPromptCase() throws {
    let data = Data(try CopilotHookSettings.source().utf8)
    let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let hooks = try #require(root["hooks"] as? [String: [[String: Any]]])
    let bash = try #require(hooks["notification"]?.first?["bash"] as? String)

    let caseStart = try #require(bash.range(of: "case \"$__in\" in *permission_prompt*|*elicitation_dialog*)"))
    // Backwards: `ttyResolveSnippet` nests its own `case … esac`, so the outer one is last.
    let caseEnd = try #require(bash.range(of: "esac", options: .backwards))
    let branch = bash[caseStart.upperBound..<caseEnd.lowerBound]
    #expect(branch.contains("event=awaiting_input"))
    #expect(branch.contains("kind=notify"))
  }

  @Test func installStateNotInstalledForNonUTF8File() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = CopilotHooksInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try fileManager.createDirectory(
      at: installer.hookFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data([0xFF, 0xFE, 0xFD]).write(to: installer.hookFileURL)

    #expect(installer.installState() == .notInstalled)
  }
}
