import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

struct AntigravitySettingsInstallerTests {
  private let fileManager = FileManager.default

  private func makeTempHomeURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("supacode-antigravity-installer-\(UUID().uuidString)", isDirectory: true)
  }

  // MARK: - Install / Uninstall

  @Test func installStateIsNotInstalledWhenFileMissing() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = AntigravitySettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    #expect(installer.installState() == .notInstalled)
  }

  @Test func installWritesHookSettingsWhenMissing() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = AntigravitySettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    #expect(installer.installState() == .notInstalled)

    try installer.installAllHooks()
    #expect(installer.installState() == .installed)

    let settingsURL = AntigravitySettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    let mainSettingsURL = AntigravitySettingsInstaller.mainSettingsURL(homeDirectoryURL: homeURL)
    #expect(fileManager.fileExists(atPath: settingsURL.path))
    #expect(fileManager.fileExists(atPath: mainSettingsURL.path))

    let hooksData = try Data(contentsOf: settingsURL)
    let hooksJson = try JSONDecoder().decode(JSONValue.self, from: hooksData)
    let hooksObj = try #require(hooksJson.objectValue)

    let settingsData = try Data(contentsOf: mainSettingsURL)
    let settingsJson = try JSONDecoder().decode(JSONValue.self, from: settingsData)

    #expect(settingsJson.objectValue?["enable_json_hooks"]?.boolValue == true)
    #expect(settingsJson.objectValue?["enableJsonHooks"]?.boolValue == true)

    let supacodeHooks = try #require(hooksObj["supacode-hooks"]?.objectValue)
    #expect(supacodeHooks["SessionStart"] != nil)
    #expect(supacodeHooks["PreToolUse"] != nil)
    #expect(supacodeHooks["PostToolUse"] != nil)
    #expect(supacodeHooks["PreInvocation"] != nil)
    #expect(supacodeHooks["PostInvocation"] != nil)
    #expect(supacodeHooks["Stop"] != nil)
  }

  @Test func installIsIdempotent() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = AntigravitySettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.installAllHooks()
    let settingsURL = AntigravitySettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    let firstData = try Data(contentsOf: settingsURL)
    let firstJson = try JSONDecoder().decode(JSONValue.self, from: firstData)

    try installer.installAllHooks()
    let secondData = try Data(contentsOf: settingsURL)
    let secondJson = try JSONDecoder().decode(JSONValue.self, from: secondData)

    #expect(firstJson == secondJson)
  }

  @Test func installStateReturnsOutdatedWhenFeatureToggleIsDisabled() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = AntigravitySettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.installAllHooks()
    #expect(installer.installState() == .installed)

    let mainSettingsURL = AntigravitySettingsInstaller.mainSettingsURL(homeDirectoryURL: homeURL)
    let disabledFlags: [String: JSONValue] = [
      "enable_json_hooks": .bool(false),
      "enableJsonHooks": .bool(false),
    ]
    let disabledData = try JSONEncoder().encode(JSONValue.object(disabledFlags))
    try disabledData.write(to: mainSettingsURL)

    #expect(installer.installState() == .outdated)
  }

  @Test func installStateReturnsInstalledWhenOnlyOneFeatureToggleIsEnabled() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = AntigravitySettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.installAllHooks()

    let mainSettingsURL = AntigravitySettingsInstaller.mainSettingsURL(homeDirectoryURL: homeURL)

    // Test enable_json_hooks only
    let snakeCaseOnly: [String: JSONValue] = ["enable_json_hooks": .bool(true)]
    let snakeData = try JSONEncoder().encode(JSONValue.object(snakeCaseOnly))
    try snakeData.write(to: mainSettingsURL)
    #expect(installer.installState() == .installed)

    // Test enableJsonHooks only
    let camelCaseOnly: [String: JSONValue] = ["enableJsonHooks": .bool(true)]
    let camelData = try JSONEncoder().encode(JSONValue.object(camelCaseOnly))
    try camelData.write(to: mainSettingsURL)
    #expect(installer.installState() == .installed)
  }

  @Test func installStateReturnsOutdatedWhenLegacyRootHooksExist() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = AntigravitySettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.installAllHooks()

    let settingsURL = AntigravitySettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    let settingsData = try Data(contentsOf: settingsURL)
    var settingsJson = (try JSONDecoder().decode(JSONValue.self, from: settingsData)).objectValue ?? [:]

    let legacyCommand = "/path/to/script.sh # supacode-managed-hook"
    let legacyHook: JSONValue = .object(["command": .string(legacyCommand)])
    settingsJson["SessionStart"] = .array([legacyHook])

    let updatedData = try JSONEncoder().encode(JSONValue.object(settingsJson))
    try updatedData.write(to: settingsURL)

    #expect(installer.installState() == .outdated)
  }

  @Test func installPreservesUserRootHooksAndCustomSupacodeHooks() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let settingsURL = AntigravitySettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    let mainSettingsURL = AntigravitySettingsInstaller.mainSettingsURL(homeDirectoryURL: homeURL)
    try fileManager.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)

    let userRootHook: JSONValue = .object(["command": .string("/usr/local/bin/user-script.sh")])
    let userSupacodeHook: JSONValue = .object(["command": .string("/usr/local/bin/custom-agent.sh")])
    let initialConfig: [String: JSONValue] = [
      "SessionStart": .array([userRootHook]),
      "supacode-hooks": .object([
        "PreToolUse": .array([userSupacodeHook])
      ]),
    ]
    let initialData = try JSONEncoder().encode(JSONValue.object(initialConfig))
    try initialData.write(to: settingsURL)

    let installer = AntigravitySettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.installAllHooks()

    #expect(installer.installState() == .installed)
    #expect(fileManager.fileExists(atPath: mainSettingsURL.path))

    let settingsData = try Data(contentsOf: mainSettingsURL)
    let settingsJson = (try JSONDecoder().decode(JSONValue.self, from: settingsData)).objectValue ?? [:]
    #expect(settingsJson["enable_json_hooks"]?.boolValue == true)

    let installedData = try Data(contentsOf: settingsURL)
    let installedObj = (try JSONDecoder().decode(JSONValue.self, from: installedData)).objectValue ?? [:]

    let rootSessionStart = try #require(installedObj["SessionStart"]?.arrayValue)
    #expect(rootSessionStart.contains(userRootHook))

    let supacodeHooks = try #require(installedObj["supacode-hooks"]?.objectValue)
    let preToolUseHooks = try #require(supacodeHooks["PreToolUse"]?.arrayValue)
    #expect(preToolUseHooks.contains(userSupacodeHook))
  }

  @Test func installAndUninstallPreservesSingleObjectUserHooks() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let settingsURL = AntigravitySettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    try fileManager.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)

    let singleRootHook: JSONValue = .object(["command": .string("/usr/local/bin/single-user-script.sh")])
    let singleSupacodeHook: JSONValue = .object(["command": .string("/usr/local/bin/single-custom-agent.sh")])
    let initialConfig: [String: JSONValue] = [
      "SessionStart": singleRootHook,
      "supacode-hooks": .object([
        "PreToolUse": singleSupacodeHook
      ]),
    ]
    let initialData = try JSONEncoder().encode(JSONValue.object(initialConfig))
    try initialData.write(to: settingsURL)

    let installer = AntigravitySettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.installAllHooks()

    let installedData = try Data(contentsOf: settingsURL)
    let installedObj = (try JSONDecoder().decode(JSONValue.self, from: installedData)).objectValue ?? [:]

    // Root-level SessionStart has no Supacode hooks, so it stays as the original single object.
    #expect(installedObj["SessionStart"] == singleRootHook)

    // supacode-hooks PreToolUse merges the user's single-object hook into an array with canonical hooks.
    let supacodeHooks = try #require(installedObj["supacode-hooks"]?.objectValue)
    let preToolUseHooks = try #require(supacodeHooks["PreToolUse"]?.arrayValue)
    #expect(preToolUseHooks.contains(singleSupacodeHook))

    // Verify managed hooks are present after install.
    let managedHooksExist = preToolUseHooks.contains { hookValue in
      guard let command = hookValue.objectValue?["command"]?.stringValue else { return false }
      return command.contains("supacode-managed-hook")
    }
    #expect(managedHooksExist)

    try installer.uninstallAllHooks()

    let uninstalledData = try Data(contentsOf: settingsURL)
    let uninstalledObj = (try JSONDecoder().decode(JSONValue.self, from: uninstalledData)).objectValue ?? [:]

    // Root-level SessionStart still preserved as original single object.
    #expect(uninstalledObj["SessionStart"] == singleRootHook)

    let remainingSupacodeHooks = try #require(uninstalledObj["supacode-hooks"]?.objectValue)
    #expect(remainingSupacodeHooks.keys.count == 1)
    let remainingPreToolUse = try #require(remainingSupacodeHooks["PreToolUse"]?.arrayValue)
    #expect(remainingPreToolUse.contains(singleSupacodeHook))

    // Verify managed hooks were actually removed.
    let managedHooksRemain = remainingPreToolUse.contains { hookValue in
      guard let command = hookValue.objectValue?["command"]?.stringValue else { return false }
      return command.contains("supacode-managed-hook")
    }
    #expect(!managedHooksRemain)
  }

  @Test func uninstallRemovesHooksAndMainSettingsFlags() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = AntigravitySettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    let settingsURL = AntigravitySettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    let mainSettingsURL = AntigravitySettingsInstaller.mainSettingsURL(homeDirectoryURL: homeURL)

    try installer.installAllHooks()
    #expect(installer.installState() == .installed)
    #expect(fileManager.fileExists(atPath: settingsURL.path))
    #expect(fileManager.fileExists(atPath: mainSettingsURL.path))

    try installer.uninstallAllHooks()
    #expect(installer.installState() == .notInstalled)
    #expect(!fileManager.fileExists(atPath: settingsURL.path))
    #expect(!fileManager.fileExists(atPath: mainSettingsURL.path))
  }

  @Test func uninstallPreservesOtherMainSettings() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = AntigravitySettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    let mainSettingsURL = AntigravitySettingsInstaller.mainSettingsURL(homeDirectoryURL: homeURL)

    try installer.installAllHooks()

    let settingsData = try Data(contentsOf: mainSettingsURL)
    var settingsJson = (try JSONDecoder().decode(JSONValue.self, from: settingsData)).objectValue ?? [:]
    settingsJson["user_preference"] = .string("custom")
    let updatedData = try JSONEncoder().encode(JSONValue.object(settingsJson))
    try updatedData.write(to: mainSettingsURL)

    try installer.uninstallAllHooks()
    #expect(fileManager.fileExists(atPath: mainSettingsURL.path))
    let remainingData = try Data(contentsOf: mainSettingsURL)
    let remainingJson = (try JSONDecoder().decode(JSONValue.self, from: remainingData)).objectValue ?? [:]
    #expect(remainingJson["enable_json_hooks"] == nil)
    #expect(remainingJson["enableJsonHooks"] == nil)
    #expect(remainingJson["user_preference"]?.stringValue == "custom")
  }

  @Test func uninstallPreservesUserHooksAndRetainsMainSettingsFlags() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = AntigravitySettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    let mainSettingsURL = AntigravitySettingsInstaller.mainSettingsURL(homeDirectoryURL: homeURL)
    try installer.installAllHooks()

    let settingsURL = AntigravitySettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    let settingsData = try Data(contentsOf: settingsURL)
    var settingsJson = (try JSONDecoder().decode(JSONValue.self, from: settingsData)).objectValue ?? [:]

    let userRootHook: JSONValue = .object(["command": .string("/usr/local/bin/user-script.sh")])
    let userSupacodeHook: JSONValue = .object(["command": .string("/usr/local/bin/custom-agent.sh")])

    settingsJson["SessionStart"] = .array([userRootHook])
    var supacodeHooks = settingsJson["supacode-hooks"]?.objectValue ?? [:]
    var preToolUse = supacodeHooks["PreToolUse"]?.arrayValue ?? []
    preToolUse.append(userSupacodeHook)
    supacodeHooks["PreToolUse"] = .array(preToolUse)
    settingsJson["supacode-hooks"] = .object(supacodeHooks)

    let updatedData = try JSONEncoder().encode(JSONValue.object(settingsJson))
    try updatedData.write(to: settingsURL)

    try installer.uninstallAllHooks()

    #expect(fileManager.fileExists(atPath: settingsURL.path))
    let remainingData = try Data(contentsOf: settingsURL)
    let remainingObj = (try JSONDecoder().decode(JSONValue.self, from: remainingData)).objectValue ?? [:]

    let rootSessionStart = try #require(remainingObj["SessionStart"]?.arrayValue)
    #expect(rootSessionStart.contains(userRootHook))

    let remainingSupacodeHooks = try #require(remainingObj["supacode-hooks"]?.objectValue)
    #expect(remainingSupacodeHooks.keys.count == 1)
    let remainingPreToolUse = try #require(remainingSupacodeHooks["PreToolUse"]?.arrayValue)
    #expect(remainingPreToolUse.contains(userSupacodeHook))

    // Verify managed hooks were actually removed from supacode-hooks.
    let managedHooksRemain = remainingPreToolUse.contains { hookValue in
      guard let command = hookValue.objectValue?["command"]?.stringValue else { return false }
      return command.contains("supacode-managed-hook")
    }
    #expect(!managedHooksRemain)

    #expect(fileManager.fileExists(atPath: mainSettingsURL.path))
    let mainSettingsData = try Data(contentsOf: mainSettingsURL)
    let mainSettingsJson = (try JSONDecoder().decode(JSONValue.self, from: mainSettingsData)).objectValue ?? [:]
    #expect(mainSettingsJson["enable_json_hooks"]?.boolValue == true)
    #expect(mainSettingsJson["enableJsonHooks"]?.boolValue == true)
  }

  // MARK: - Drift detection

  @Test func installStateIsNotInstalledForPreexistingHooksWithoutSupacode() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    // A user of the Gemini CLI already has a hooks.json with their own hook and no settings.json,
    // and never installed Supacode. It must read as notInstalled so auto-update doesn't silently
    // install hooks over a config the user never opted into.
    let settingsURL = AntigravitySettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    try fileManager.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)

    let userConfig: [String: JSONValue] = [
      "SessionStart": .array([.object(["command": .string("/usr/local/bin/user.sh")])])
    ]
    try encode(userConfig, to: settingsURL)

    let installer = AntigravitySettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    #expect(installer.installState() == .notInstalled)

    // An empty-object hooks.json is likewise notInstalled.
    try encode([:], to: settingsURL)
    #expect(installer.installState() == .notInstalled)
  }

  @Test func installStateReturnsOutdatedWhenAManagedEventIsRemoved() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = AntigravitySettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.installAllHooks()
    #expect(installer.installState() == .installed)

    // PreToolUse shares its managed busy command with PreInvocation. A flattened command-set check
    // would still see busy and report installed; per-event detection must flag the missing event.
    let settingsURL = AntigravitySettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    var root = try decodeObject(at: settingsURL)
    var supacodeHooks = try #require(root["supacode-hooks"]?.objectValue)
    #expect(supacodeHooks["PreToolUse"] != nil)
    #expect(supacodeHooks["PreInvocation"] != nil)
    supacodeHooks.removeValue(forKey: "PreToolUse")
    root["supacode-hooks"] = .object(supacodeHooks)
    try encode(root, to: settingsURL)

    #expect(installer.installState() == .outdated)
  }

  @Test func installStateReturnsOutdatedWhenAnEventUsesAnotherEventsCommand() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = AntigravitySettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.installAllHooks()
    #expect(installer.installState() == .installed)

    // Swap PreToolUse's managed command for PostInvocation's (idle). The flattened command set is
    // unchanged, so only a per-event comparison can tell PreToolUse now carries the wrong command.
    let settingsURL = AntigravitySettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    var root = try decodeObject(at: settingsURL)
    var supacodeHooks = try #require(root["supacode-hooks"]?.objectValue)
    let idleCommand = try #require(
      supacodeHooks["PostInvocation"]?.arrayValue?.first?.objectValue?["command"]?.stringValue)
    supacodeHooks["PreToolUse"] = .array([.object(["command": .string(idleCommand)])])
    root["supacode-hooks"] = .object(supacodeHooks)
    try encode(root, to: settingsURL)

    #expect(installer.installState() == .outdated)
  }

  @Test func installStateIsNotInstalledForCorruptHooksJson() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    // A corrupt hooks.json must degrade gracefully to notInstalled, not trap.
    let settingsURL = AntigravitySettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    try fileManager.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{ not json".utf8).write(to: settingsURL)

    let installer = AntigravitySettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    #expect(installer.installState() == .notInstalled)
  }

  @Test func installStateIsNotInstalledWhenAnEventEntryIsMalformed() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = AntigravitySettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.installAllHooks()
    #expect(installer.installState() == .installed)

    // A scalar entry alongside the canonical hooks is a shape install/uninstall reject, so the
    // state must stop reporting installed.
    let settingsURL = AntigravitySettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    var root = try decodeObject(at: settingsURL)
    var supacodeHooks = try #require(root["supacode-hooks"]?.objectValue)
    supacodeHooks["GarbageEvent"] = .int(5)
    root["supacode-hooks"] = .object(supacodeHooks)
    try encode(root, to: settingsURL)

    #expect(installer.installState() == .notInstalled)
  }

  // MARK: - Legacy migration

  @Test func installMigratesLegacyRootHooksPreservingUserHooks() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let settingsURL = AntigravitySettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    try fileManager.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)

    // Old flat-root schema: a Supacode-managed hook sits at root SessionStart next to a user hook.
    let legacyManaged: JSONValue = .object(["command": .string("/legacy/agent.sh # supacode-managed-hook")])
    let userRootHook: JSONValue = .object(["command": .string("/usr/local/bin/user-root.sh")])
    let initial: [String: JSONValue] = ["SessionStart": .array([legacyManaged, userRootHook])]
    try encode(initial, to: settingsURL)

    let installer = AntigravitySettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.installAllHooks()

    let root = try decodeObject(at: settingsURL)
    let rootSessionStart = try #require(root["SessionStart"]?.arrayValue)
    #expect(rootSessionStart.contains(userRootHook))
    #expect(!rootSessionStart.contains(legacyManaged))
    let managedRemainsAtRoot = rootSessionStart.contains { hookValue in
      hookValue.objectValue?["command"]?.stringValue?.contains("supacode-managed-hook") == true
    }
    #expect(!managedRemainsAtRoot)

    // Canonical hooks now live under supacode-hooks and the migrated config reads as installed.
    #expect(root["supacode-hooks"]?.objectValue?["SessionStart"] != nil)
    #expect(installer.installState() == .installed)
  }

  // MARK: - Malformed shape rejection

  @Test func installRejectsNonObjectSupacodeHooksNamespace() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let settingsURL = AntigravitySettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    try fileManager.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encode(["supacode-hooks": .string("nope")], to: settingsURL)

    let installer = AntigravitySettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    #expect(throws: AntigravitySettingsInstallerError.invalidHooksObject) {
      try installer.installAllHooks()
    }

    // The user's value is rejected, not silently overwritten.
    let root = try decodeObject(at: settingsURL)
    #expect(root["supacode-hooks"]?.stringValue == "nope")
  }

  @Test func installRejectsScalarEventEntryUnderSupacodeHooks() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let settingsURL = AntigravitySettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    try fileManager.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encode(["supacode-hooks": .object(["PreToolUse": .int(42)])], to: settingsURL)

    let installer = AntigravitySettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    #expect(throws: AntigravitySettingsInstallerError.invalidEventHooks("PreToolUse")) {
      try installer.installAllHooks()
    }

    // The malformed value is rejected, not rewritten.
    let root = try decodeObject(at: settingsURL)
    #expect(root["supacode-hooks"]?.objectValue?["PreToolUse"] == .int(42))
  }

  @Test func uninstallRejectsScalarEventEntryUnderSupacodeHooks() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    // Uninstall applies the same shape validation as install (symmetric with the sibling
    // installers): a malformed namespace is surfaced rather than silently half-processed.
    let settingsURL = AntigravitySettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    try fileManager.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encode(["supacode-hooks": .object(["PreToolUse": .int(42)])], to: settingsURL)

    let installer = AntigravitySettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    #expect(throws: AntigravitySettingsInstallerError.invalidEventHooks("PreToolUse")) {
      try installer.uninstallAllHooks()
    }
  }

  @Test func uninstallDoesNotThrowOnCorruptMainSettings() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = AntigravitySettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.installAllHooks()

    let mainSettingsURL = AntigravitySettingsInstaller.mainSettingsURL(homeDirectoryURL: homeURL)
    try Data("{ corrupt".utf8).write(to: mainSettingsURL)

    // Uninstall removes the hooks and must not blow up on a bad settings.json.
    try installer.uninstallAllHooks()

    let settingsURL = AntigravitySettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    #expect(!fileManager.fileExists(atPath: settingsURL.path))
    // The corrupt main settings are left untouched rather than deleted or rewritten.
    #expect(fileManager.fileExists(atPath: mainSettingsURL.path))
    let raw = String(data: try Data(contentsOf: mainSettingsURL), encoding: .utf8)
    #expect(raw == "{ corrupt")
  }

  // MARK: - Helpers

  private func decodeObject(at url: URL) throws -> [String: JSONValue] {
    let data = try Data(contentsOf: url)
    return (try JSONDecoder().decode(JSONValue.self, from: data)).objectValue ?? [:]
  }

  private func encode(_ object: [String: JSONValue], to url: URL) throws {
    let data = try JSONEncoder().encode(JSONValue.object(object))
    try data.write(to: url)
  }
}
