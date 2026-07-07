import Foundation
import Testing

@testable import SupacodeSettingsShared

struct GrokSettingsInstallerTests {
  private let fileManager = FileManager.default

  private func makeTempHomeURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("supacode-grok-installer-\(UUID().uuidString)", isDirectory: true)
  }

  @Test func installStateIsNotInstalledWhenFileMissing() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = GrokSettingsInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    #expect(installer.installState() == .notInstalled)
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
}
