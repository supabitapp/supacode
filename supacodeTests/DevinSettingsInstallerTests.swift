import Foundation
import Testing

@testable import SupacodeSettingsShared

struct DevinSettingsInstallerTests {
  private let fileManager = FileManager.default

  private func makeTempHomeURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("supacode-devin-installer-\(UUID().uuidString)", isDirectory: true)
  }

  @Test func installStateIsNotInstalledWhenFileMissing() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = DevinSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    #expect(try installer.installState() == .notInstalled)
  }

  @Test func installStateThrowsWhenFileIsUnreadableAsUTF8() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let settingsURL = DevinSettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    try fileManager.createDirectory(
      at: settingsURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    // Lead bytes that are invalid UTF-8: the file exists but yields no state,
    // which must not be reported as "not installed".
    try Data([0xFF, 0xFE, 0xFD, 0x00]).write(to: settingsURL)

    let installer = DevinSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    #expect(throws: (any Error).self) { try installer.installState() }
  }

  @Test func installStateReturnsOutdatedWhenManagedBodyDrifted() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let settingsURL = DevinSettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    try fileManager.createDirectory(
      at: settingsURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    // Ownership marker present but SessionStart carries a stale busy command:
    // an older Supacode wrote this, so the user must get the Update affordance.
    let staleCommand = AgentHookSettingsCommand.compositeCommand(
      events: [.busy], forwardStdinAsNotification: false, agent: .devin)
    let stale: JSONValue = .object([
      "hooks": .object([
        "SessionStart": .array([
          .object([
            "hooks": .array([
              .object([
                "type": "command",
                "command": .string(staleCommand),
                "timeout": 5,
              ])
            ])
          ])
        ])
      ])
    ])
    try JSONEncoder().encode(stale).write(to: settingsURL)

    let installer = DevinSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    #expect(try installer.installState() == .outdated)
  }

  @Test func installStateReturnsOutdatedWhenOneDuplicateBusyHookIsRemoved() throws {
    // Devin's canonical payload reuses the same `busy` command under both
    // UserPromptSubmit and the catch-all PreToolUse group. Removing only the
    // PreToolUse occurrence must read as drift — a command-string Set compare
    // would still see `busy` and wrongly report `.installed`.
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = DevinSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.installAllHooks()

    let settingsURL = DevinSettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    var root = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: settingsURL))
      .objectValue!
    var hooks = root["hooks"]!.objectValue!
    // Drop the catch-all PreToolUse group (matcher ""), keep the awaiting-input
    // matcher group — the user's other managed hooks stay untouched.
    hooks["PreToolUse"] = .array(
      hooks["PreToolUse"]!.arrayValue!
        .filter { $0.objectValue?["matcher"] != .string("") })
    root["hooks"] = .object(hooks)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(.object(root)).write(to: settingsURL)

    #expect(try installer.installState() == .outdated)
  }

  @Test func installStateReturnsOutdatedWhenPreToolUseMatcherOrderIsReversed() throws {
    // Devin's PreToolUse groups execute in array order: the catch-all busy
    // matcher must precede the awaiting-input matcher so ask_user_question
    // resolves to awaiting_input. Reversed groups leave every command present
    // but flip which emit wins — the compare must be order-sensitive.
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = DevinSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.installAllHooks()

    let settingsURL = DevinSettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    var root = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: settingsURL))
      .objectValue!
    var hooks = root["hooks"]!.objectValue!
    hooks["PreToolUse"] = .array(hooks["PreToolUse"]!.arrayValue!.reversed())
    root["hooks"] = .object(hooks)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(.object(root)).write(to: settingsURL)

    #expect(try installer.installState() == .outdated)
  }

  @Test func installAllHooksWritesManagedHooksIntoConfigJson() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = DevinSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.installAllHooks()

    let settingsURL = DevinSettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    #expect(fileManager.fileExists(atPath: settingsURL.path))

    let data = try Data(contentsOf: settingsURL)
    let root = try JSONDecoder().decode(JSONValue.self, from: data)
    #expect(root.objectValue?["hooks"]?.objectValue?["SessionStart"] != nil)
    #expect(root.objectValue?["hooks"]?.objectValue?["PermissionRequest"] != nil)
    #expect(try installer.installState() == .installed)
  }

  @Test func uninstallRemovesManagedHooks() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = DevinSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.installAllHooks()
    try installer.uninstallAllHooks()

    let settingsURL = DevinSettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    let data = try Data(contentsOf: settingsURL)
    let root = try JSONDecoder().decode(JSONValue.self, from: data)
    let hooksObject = root.objectValue?["hooks"]?.objectValue ?? [:]
    #expect(hooksObject.isEmpty)
    #expect(try installer.installState() == .notInstalled)
  }

  @Test func installPreservesOtherConfigKeysAndUserAuthoredHooks() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    // config.json is Devin's main settings file: sibling keys (model,
    // permissions, read_config_from, …) and user-authored hooks must survive.
    let settingsURL = DevinSettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    try fileManager.createDirectory(
      at: settingsURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let existing = """
      {
        "model": "opus-4.5",
        "permissions": { "allow": ["exec(git status)"] },
        "hooks": {
          "PostToolUse": [
            {
              "hooks": [
                {
                  "type": "command",
                  "command": "prettier --write"
                }
              ]
            }
          ]
        }
      }
      """
    try existing.write(to: settingsURL, atomically: true, encoding: .utf8)

    let installer = DevinSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.installAllHooks()

    let data = try Data(contentsOf: settingsURL)
    let root = try JSONDecoder().decode(JSONValue.self, from: data)
    #expect(root.objectValue?["model"]?.stringValue == "opus-4.5")
    #expect(root.objectValue?["permissions"]?.objectValue != nil)

    let text = try String(contentsOf: settingsURL, encoding: .utf8)
    #expect(text.contains("prettier --write"))
    #expect(text.contains(AgentHookSettingsCommand.ownershipMarker))
    #expect(try installer.installState() == .installed)
  }

  @Test func uninstallPreservesOtherConfigKeysAndUserAuthoredHooks() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let settingsURL = DevinSettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    try fileManager.createDirectory(
      at: settingsURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let existing = """
      {
        "model": "opus-4.5",
        "hooks": {
          "PostToolUse": [
            {
              "hooks": [
                {
                  "type": "command",
                  "command": "prettier --write"
                }
              ]
            }
          ]
        }
      }
      """
    try existing.write(to: settingsURL, atomically: true, encoding: .utf8)

    let installer = DevinSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.installAllHooks()
    try installer.uninstallAllHooks()

    let data = try Data(contentsOf: settingsURL)
    let root = try JSONDecoder().decode(JSONValue.self, from: data)
    #expect(root.objectValue?["model"]?.stringValue == "opus-4.5")

    let text = try String(contentsOf: settingsURL, encoding: .utf8)
    #expect(text.contains("prettier --write"))
    #expect(!text.contains(AgentHookSettingsCommand.ownershipMarker))
    #expect(try installer.installState() == .notInstalled)
  }
}
