import Foundation
import Testing

@testable import SupacodeSettingsShared

struct GrokSettingsInstallerTests {
  private let fileManager = FileManager.default

  private func makeTempHomeURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("supacode-grok-installer-\(UUID().uuidString)", isDirectory: true)
  }

  /// Rewrites every hook's `env` map on disk via `transform`; returning nil
  /// drops the `env` key. Simulates an older install whose commands still
  /// match but whose env passthrough is absent, partial, or drifted.
  /// When `event` is set, only that event's hooks are rewritten.
  private func rewriteManagedHookEnv(
    at settingsURL: URL,
    event: String? = nil,
    transform: ([String: JSONValue]?) -> [String: JSONValue]?
  ) throws {
    let data = try Data(contentsOf: settingsURL)
    guard
      var rootObject = try JSONDecoder().decode(JSONValue.self, from: data).objectValue,
      var hooksObject = rootObject["hooks"]?.objectValue
    else { return }
    for (eventName, value) in hooksObject {
      if let event, eventName != event { continue }
      guard let groups = value.arrayValue else { continue }
      hooksObject[eventName] = .array(
        groups.map { group in
          guard
            var groupObject = group.objectValue,
            let hooks = groupObject["hooks"]?.arrayValue
          else { return group }
          groupObject["hooks"] = .array(
            hooks.map { hook in
              guard var hookObject = hook.objectValue else { return hook }
              hookObject["env"] = transform(hookObject["env"]?.objectValue).map { .object($0) }
              return .object(hookObject)
            })
          return .object(groupObject)
        })
    }
    rootObject["hooks"] = .object(hooksObject)
    try JSONEncoder().encode(JSONValue.object(rootObject)).write(to: settingsURL)
  }

  private func loadSettingsObject(at settingsURL: URL) throws -> [String: JSONValue] {
    let data = try Data(contentsOf: settingsURL)
    return try #require(try JSONDecoder().decode(JSONValue.self, from: data).objectValue)
  }

  @Test func installStateIsNotInstalledWhenFileMissing() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = GrokSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    #expect(installer.installState() == .notInstalled)
  }

  @Test func installStateIsNotInstalledWhenFileIsUnreadableAsUTF8() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let settingsURL = GrokSettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    try fileManager.createDirectory(
      at: settingsURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    // Lead bytes that are invalid UTF-8: an unreadable file resolves to
    // not-installed rather than crashing or false-positiving as installed.
    try Data([0xFF, 0xFE, 0xFD, 0x00]).write(to: settingsURL)

    let installer = GrokSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    #expect(installer.installState() == .notInstalled)
  }

  @Test func installStateReturnsOutdatedWhenEnvPassthroughMissing() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = GrokSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.installAllHooks()
    #expect(installer.installState() == .installed)

    // An older install carries the full canonical command set but no env
    // blocks. The command set still matches, so only the env check can flag it.
    let settingsURL = GrokSettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    try rewriteManagedHookEnv(at: settingsURL) { _ in nil }

    #expect(installer.installState() == .outdated)
  }

  @Test func installStateReturnsOutdatedWhenEnvPassthroughIncomplete() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = GrokSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.installAllHooks()
    #expect(installer.installState() == .installed)

    // Only the surface id survives: a partial env map is still outdated.
    let settingsURL = GrokSettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    try rewriteManagedHookEnv(at: settingsURL) { _ in
      ["SUPACODE_SURFACE_ID": .string("${SUPACODE_SURFACE_ID}")]
    }

    #expect(installer.installState() == .outdated)
  }

  @Test func installStateReturnsOutdatedWhenEnvPassthroughValueDrifted() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = GrokSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.installAllHooks()
    #expect(installer.installState() == .installed)

    // A stale literal value (not the `${VAR}` expansion) is outdated.
    let settingsURL = GrokSettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    try rewriteManagedHookEnv(at: settingsURL) { env in
      var env = env ?? [:]
      env["SUPACODE_SURFACE_ID"] = .string("stale")
      return env
    }

    #expect(installer.installState() == .outdated)
  }

  @Test func installStateReturnsOutdatedWhenSingleEventEnvMissing() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = GrokSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.installAllHooks()
    #expect(installer.installState() == .installed)

    // One managed event without env among an otherwise complete map is still
    // outdated: the detector must not require every hook to be broken.
    let settingsURL = GrokSettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    try rewriteManagedHookEnv(at: settingsURL, event: "Stop") { _ in nil }

    #expect(installer.installState() == .outdated)
    #expect(
      GrokHookSettings.managedHooksLackEnvPassthrough(in: try loadSettingsObject(at: settingsURL)))
  }

  @Test func installStateIgnoresUserAuthoredHookEnvWhenManagedMapIsComplete() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let settingsURL = GrokSettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    try fileManager.createDirectory(
      at: settingsURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    // User hook with no env must not poison the managed env detector.
    let existing = """
      {
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

    let installer = GrokSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.installAllHooks()
    #expect(installer.installState() == .installed)
    #expect(
      !GrokHookSettings.managedHooksLackEnvPassthrough(in: try loadSettingsObject(at: settingsURL)))
  }

  @Test func managedHooksHaveEnvPassthroughAfterInstall() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = GrokSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.installAllHooks()
    let settingsURL = GrokSettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    #expect(
      !GrokHookSettings.managedHooksLackEnvPassthrough(in: try loadSettingsObject(at: settingsURL)))
    #expect(installer.installState() == .installed)
  }

  @Test func installStateReturnsOutdatedWhenManagedBodyDrifted() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let settingsURL = GrokSettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    try fileManager.createDirectory(
      at: settingsURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    // Ownership marker present but SessionStart carries a stale busy command:
    // an older Supacode wrote this, so the user must get the Update affordance.
    let staleCommand = AgentHookSettingsCommand.compositeCommand(
      events: [.busy], forwardStdinAsNotification: false, agent: .grok)
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

    let installer = GrokSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    #expect(installer.installState() == .outdated)
  }

  @Test func installAllHooksWritesSupacodeManagedFile() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = GrokSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.installAllHooks()

    let settingsURL = GrokSettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    #expect(fileManager.fileExists(atPath: settingsURL.path))

    let data = try Data(contentsOf: settingsURL)
    let root = try JSONDecoder().decode(JSONValue.self, from: data)
    #expect(root.objectValue?["hooks"]?.objectValue?["SessionStart"] != nil)
    let sessionStartHook = try #require(
      root.objectValue?["hooks"]?.objectValue?["SessionStart"]?.arrayValue?.first?
        .objectValue?["hooks"]?.arrayValue?.first?.objectValue
    )
    let env = try #require(sessionStartHook["env"]?.objectValue)
    #expect(env["SUPACODE_SURFACE_ID"]?.stringValue == "${SUPACODE_SURFACE_ID}")
    #expect(installer.installState() == .installed)
  }

  @Test func uninstallRemovesManagedHooks() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = GrokSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.installAllHooks()
    try installer.uninstallAllHooks()

    let settingsURL = GrokSettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    let data = try Data(contentsOf: settingsURL)
    let root = try JSONDecoder().decode(JSONValue.self, from: data)
    let hooksObject = root.objectValue?["hooks"]?.objectValue ?? [:]
    #expect(hooksObject.isEmpty)
    #expect(installer.installState() == .notInstalled)
  }

  @Test func installPreservesUserAuthoredHooksInSameFile() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let settingsURL = GrokSettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    try fileManager.createDirectory(
      at: settingsURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let existing = """
      {
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

    let installer = GrokSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.installAllHooks()

    let text = try String(contentsOf: settingsURL, encoding: .utf8)
    #expect(text.contains("prettier --write"))
    #expect(text.contains(AgentHookSettingsCommand.ownershipMarker))
    #expect(installer.installState() == .installed)
  }

  @Test func uninstallPreservesUserAuthoredHooksInSameFile() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let settingsURL = GrokSettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    try fileManager.createDirectory(
      at: settingsURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let existing = """
      {
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

    let installer = GrokSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.installAllHooks()
    try installer.uninstallAllHooks()

    let text = try String(contentsOf: settingsURL, encoding: .utf8)
    #expect(text.contains("prettier --write"))
    #expect(!text.contains(AgentHookSettingsCommand.ownershipMarker))
    #expect(installer.installState() == .notInstalled)
  }
}
