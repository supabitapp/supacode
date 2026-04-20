import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

struct KiroSettingsInstallerTests {
  private let fileManager = FileManager.default

  private func makeTempHomeURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("supacode-kiro-installer-\(UUID().uuidString)", isDirectory: true)
  }

  @Test func installProgressHooksCreatesDefaultConfigWhenMissing() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = KiroSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.installProgressHooks()

    let settingsURL = KiroSettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    let data = try Data(contentsOf: settingsURL)
    let json = try JSONDecoder().decode(JSONValue.self, from: data)
    let root = try #require(json.objectValue)
    #expect(root["name"] == .string("kiro_default"))
    #expect(root["tools"] == .array([.string("*")]))
    #expect(root["useLegacyMcpJson"] == .bool(true))
    let resources = try #require(root["resources"]?.arrayValue)
    #expect(resources.count == 4)
    #expect(resources.contains(.string("file://AGENTS.md")))
    #expect(resources.contains(.string("skill://~/.kiro/skills/**/SKILL.md")))
    #expect(resources.contains(.string("skill://~/.kiro/steering/**/*.md")))
    #expect(root["hooks"]?.objectValue != nil)
  }

  @Test func installNotificationHooksCreatesDefaultConfigWhenMissing() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = KiroSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.installNotificationHooks()

    let settingsURL = KiroSettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    let data = try Data(contentsOf: settingsURL)
    let json = try JSONDecoder().decode(JSONValue.self, from: data)
    let root = try #require(json.objectValue)
    #expect(root["name"] == .string("kiro_default"))
    #expect(root["tools"] == .array([.string("*")]))
  }

  @Test func installProgressHooksDoesNotOverwriteExistingConfig() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = KiroSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.installProgressHooks()

    let settingsURL = KiroSettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    let firstWrite = try Data(contentsOf: settingsURL)

    // Second install should not recreate the base config.
    try installer.installProgressHooks()
    let secondWrite = try Data(contentsOf: settingsURL)

    #expect(firstWrite == secondWrite)
  }

  @Test func uninstallProgressHooksIsNoOpWhenFileMissing() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = KiroSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    // Must not throw even when the file doesn't exist.
    #expect(throws: Never.self) {
      try installer.uninstallProgressHooks()
    }
  }

  @Test func uninstallNotificationHooksIsNoOpWhenFileMissing() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = KiroSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    #expect(throws: Never.self) {
      try installer.uninstallNotificationHooks()
    }
  }

  @Test func isInstalledProgressReturnsFalseBeforeInstall() {
    let homeURL = makeTempHomeURL()
    let installer = KiroSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    #expect(installer.isInstalled(progress: true) == false)
  }

  @Test func isInstalledProgressReturnsTrueAfterInstall() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = KiroSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.installProgressHooks()
    #expect(installer.isInstalled(progress: true) == true)
  }

  @Test func isInstalledNotificationsReturnsTrueAfterInstall() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = KiroSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.installNotificationHooks()
    #expect(installer.isInstalled(progress: false) == true)
  }

  @Test func isInstalledProgressReturnsFalseAfterUninstall() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = KiroSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.installProgressHooks()
    try installer.uninstallProgressHooks()
    #expect(installer.isInstalled(progress: true) == false)
  }

  @Test func settingsURLPointsToExpectedPath() {
    let homeURL = URL(fileURLWithPath: "/Users/test")
    let url = KiroSettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    #expect(url.path == "/Users/test/.kiro/agents/kiro_default.json")
  }
}
