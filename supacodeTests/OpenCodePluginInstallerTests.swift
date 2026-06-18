import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

struct OpenCodePluginInstallerTests {
  private let fileManager = FileManager.default

  private func makeTempHomeURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("supacode-opencode-plugin-\(UUID().uuidString)", isDirectory: true)
  }

  @Test func installWritesPluginFileWhenMissing() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = OpenCodePluginInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.install()

    #expect(fileManager.fileExists(atPath: installer.pluginFileURL.path))
    let contents = try String(contentsOf: installer.pluginFileURL, encoding: .utf8)
    #expect(contents == OpenCodePluginContent.source())
  }

  @Test func installIsIdempotent() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = OpenCodePluginInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.install()
    let first = try Data(contentsOf: installer.pluginFileURL)
    try installer.install()
    let second = try Data(contentsOf: installer.pluginFileURL)

    #expect(first == second)
  }

  @Test func installStateNotInstalledBeforeInstall() {
    let homeURL = makeTempHomeURL()
    let installer = OpenCodePluginInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    #expect(installer.installState() == .notInstalled)
  }

  @Test func installStateInstalledAfterInstall() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = OpenCodePluginInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.install()
    #expect(installer.installState() == .installed)
  }

  @Test func installStateOutdatedWhenContentDiffers() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = OpenCodePluginInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try fileManager.createDirectory(
      at: installer.pluginFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    // A stale Supacode plugin (carries the ownership marker but differs).
    try "// \(OpenCodePluginContent.ownershipMarker)\n// old shape"
      .write(to: installer.pluginFileURL, atomically: true, encoding: .utf8)

    #expect(installer.installState() == .outdated)
  }

  @Test func installStateNotInstalledForUnownedFileWithSameName() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = OpenCodePluginInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try fileManager.createDirectory(
      at: installer.pluginFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    // A user's own plugin at the same path must NOT report `.outdated` (which
    // auto-update would overwrite) — it isn't Supacode's to manage.
    try "export const NotSupacode = async () => ({})\n"
      .write(to: installer.pluginFileURL, atomically: true, encoding: .utf8)

    #expect(installer.installState() == .notInstalled)
  }

  @Test func uninstallRemovesOwnedPlugin() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = OpenCodePluginInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.install()
    try installer.uninstall()

    #expect(!fileManager.fileExists(atPath: installer.pluginFileURL.path))
    #expect(installer.installState() == .notInstalled)
  }

  @Test func uninstallPreservesUnownedFileWithSameName() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = OpenCodePluginInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try fileManager.createDirectory(
      at: installer.pluginFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let userPlugin = "export const NotSupacode = async () => ({})\n"
    try userPlugin.write(to: installer.pluginFileURL, atomically: true, encoding: .utf8)

    try installer.uninstall()

    let after = try String(contentsOf: installer.pluginFileURL, encoding: .utf8)
    #expect(after == userPlugin)
  }

  @Test func uninstallIsNoOpWhenMissing() {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = OpenCodePluginInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    #expect(throws: Never.self) {
      try installer.uninstall()
    }
  }

  @Test func pluginFilePointsToExpectedPath() {
    let homeURL = URL(fileURLWithPath: "/Users/test")
    let installer = OpenCodePluginInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    #expect(installer.pluginFileURL.path == "/Users/test/.config/opencode/plugins/supacode-presence.js")
  }

  // MARK: - Generated source.

  @Test func sourceCarriesOwnershipMarker() {
    #expect(OpenCodePluginContent.source().contains(OpenCodePluginContent.ownershipMarker))
  }

  @Test func sourceWiresEveryPresenceTrigger() {
    let source = OpenCodePluginContent.source()
    // The verified OpenCode hook/event surface this plugin subscribes to.
    for trigger in ["dispose", "tool.execute.before", "tool.execute.after", "permission.ask"] {
      #expect(source.contains(trigger))
    }
    #expect(source.contains("session.idle"))
    #expect(source.contains("permission.replied"))
  }

  @Test func sourceEmbedsOpenCodeScopedOSCForEveryState() {
    let source = OpenCodePluginContent.source()
    #expect(source.contains("start=opencode;event=session_start"))
    #expect(source.contains("start=opencode;event=busy"))
    #expect(source.contains("start=opencode;event=idle"))
    #expect(source.contains("start=opencode;event=awaiting_input"))
    #expect(source.contains("end=opencode;event=session_end"))
  }

  @Test func sourceDoesNotForwardNotifications() {
    // OpenCode's session.idle event has no assistant text; the notify leg is
    // intentionally omitted, so no notify OSC should appear in the plugin.
    #expect(!OpenCodePluginContent.source().contains("kind=notify"))
  }
}
