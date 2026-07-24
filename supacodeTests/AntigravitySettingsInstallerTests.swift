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
}
