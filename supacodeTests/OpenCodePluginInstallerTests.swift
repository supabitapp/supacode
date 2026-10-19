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

  private func write(_ contents: String, to url: URL) throws {
    try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try contents.write(to: url, atomically: true, encoding: .utf8)
  }

  private let userPlugin = "export const NotSupacode = async () => ({})\n"

  enum Entrypoint: CaseIterable, Sendable {
    case server, tui

    func url(in installer: OpenCodePluginInstaller) -> URL {
      switch self {
      case .server: installer.serverPluginFileURL
      case .tui: installer.tuiPluginFileURL
      }
    }
  }

  @Test func installWritesBothEntrypointsWhenMissing() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = OpenCodePluginInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.install()

    #expect(
      try String(contentsOf: installer.serverPluginFileURL, encoding: .utf8) == OpenCodePluginContent.serverSource())
    #expect(try String(contentsOf: installer.tuiPluginFileURL, encoding: .utf8) == OpenCodePluginContent.tuiSource())
  }

  @Test func installIsIdempotent() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = OpenCodePluginInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.install()
    let first = try [Data(contentsOf: installer.serverPluginFileURL), Data(contentsOf: installer.tuiPluginFileURL)]
    try installer.install()
    let second = try [Data(contentsOf: installer.serverPluginFileURL), Data(contentsOf: installer.tuiPluginFileURL)]

    #expect(first == second)
  }

  @Test func installStateNotInstalledBeforeInstall() throws {
    let homeURL = makeTempHomeURL()
    let installer = OpenCodePluginInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    #expect(try installer.installState() == .notInstalled)
  }

  @Test func installStateInstalledAfterInstall() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = OpenCodePluginInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.install()
    #expect(try installer.installState() == .installed)
  }

  @Test func installStateOutdatedForSingleFilePluginFromOlderSupacode() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = OpenCodePluginInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try write("// \(OpenCodePluginContent.ownershipMarker)\n// old shape", to: installer.serverPluginFileURL)

    #expect(try installer.installState() == .outdated)
  }

  @Test func installStateOutdatedWhenTuiEntrypointMissing() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = OpenCodePluginInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.install()
    try fileManager.removeItem(at: installer.tuiPluginFileURL)

    #expect(try installer.installState() == .outdated)
  }

  @Test func installUpgradesSingleFilePluginFromOlderSupacode() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = OpenCodePluginInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try write("// \(OpenCodePluginContent.ownershipMarker)\n// old shape", to: installer.serverPluginFileURL)
    try installer.install()

    #expect(try installer.installState() == .installed)
  }

  @Test func installStateNotInstalledForUnownedFileWithSameName() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = OpenCodePluginInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    // A user's own plugin at the same path must NOT report `.outdated` (which
    // auto-update would overwrite) — it isn't Supacode's to manage.
    try write(userPlugin, to: installer.serverPluginFileURL)

    #expect(try installer.installState() == .notInstalled)
  }

  @Test func uninstallRemovesOwnedPlugin() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = OpenCodePluginInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.install()
    try installer.uninstall()

    #expect(!fileManager.fileExists(atPath: installer.serverPluginFileURL.path))
    #expect(!fileManager.fileExists(atPath: installer.tuiPluginFileURL.deletingLastPathComponent().path))
    #expect(try installer.installState() == .notInstalled)
  }

  @Test func uninstallPreservesUnownedFileWithSameName() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = OpenCodePluginInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try write(userPlugin, to: installer.serverPluginFileURL)
    try write(userPlugin, to: installer.tuiPluginFileURL)

    try installer.uninstall()

    #expect(try String(contentsOf: installer.serverPluginFileURL, encoding: .utf8) == userPlugin)
    #expect(try String(contentsOf: installer.tuiPluginFileURL, encoding: .utf8) == userPlugin)
  }

  @Test func uninstallIsNoOpWhenMissing() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = OpenCodePluginInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    #expect(throws: Never.self) {
      try installer.uninstall()
    }
  }

  @Test(arguments: Entrypoint.allCases)
  func installRefusesToOverwriteUnownedPlugin(at entrypoint: Entrypoint) throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }
    let installer = OpenCodePluginInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try write(userPlugin, to: entrypoint.url(in: installer))

    #expect(throws: OpenCodePluginInstallerError.self) { try installer.install() }
    #expect(try String(contentsOf: entrypoint.url(in: installer), encoding: .utf8) == userPlugin)
    #expect(try installer.installState() == .notInstalled)
  }

  @Test func entrypointsPointToExpectedPaths() {
    let homeURL = URL(fileURLWithPath: "/Users/test")
    let installer = OpenCodePluginInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    #expect(installer.serverPluginFileURL.path == "/Users/test/.config/opencode/plugins/supacode-presence.js")
    #expect(installer.tuiPluginFileURL.path == "/Users/test/.config/opencode/plugins/supacode-presence/tui.js")
  }

  // MARK: - Generated sources.

  private static let sources = [OpenCodePluginContent.serverSource(), OpenCodePluginContent.tuiSource()]

  @Test(arguments: sources)
  func sourceCarriesOwnershipMarker(source: String) {
    #expect(source.contains(OpenCodePluginContent.ownershipMarker))
  }

  @Test func serverSourceLoadsUnderBothOpenCodeGenerations() {
    let source = OpenCodePluginContent.serverSource()
    // 1.x calls `server`; 2.x only accepts a default export with `id` and
    // `setup`, which it runs in its terminal-less service, so `setup` is inert.
    #expect(source.contains(#"export default { id: "supacode.presence", server, setup() {} }"#))
    #expect(!source.contains("export const"))
  }

  @Test func serverSourceWiresEveryPresenceTrigger() {
    let source = OpenCodePluginContent.serverSource()
    for trigger in [
      "dispose", "tool.execute.before", "tool.execute.after", "permission.ask", "session.idle", "permission.replied",
    ] {
      #expect(source.contains(trigger))
    }
  }

  @Test func tuiSourceWiresEveryPresenceTrigger() {
    let source = OpenCodePluginContent.tuiSource()
    #expect(source.contains(#"id: "supacode.presence.tui""#))
    for trigger in [
      "session.execution.started", "session.tool.called", "permission.replied", "form.replied", "form.cancelled",
      "permission.asked", "form.created", "session.execution.succeeded", "session.execution.interrupted",
      "session.execution.failed",
    ] {
      #expect(source.contains(#""\#(trigger)""#))
    }
  }

  @Test(arguments: sources)
  func sourceEmbedsOpenCodeScopedOSCForEveryState(source: String) {
    #expect(source.contains("start=opencode;event=session_start"))
    #expect(source.contains("start=opencode;event=busy"))
    #expect(source.contains("start=opencode;event=idle"))
    #expect(source.contains("start=opencode;event=awaiting_input"))
    #expect(source.contains("end=opencode;event=session_end"))
  }

  @Test func tuiSourceReportsFailedExecutionsAsErrors() {
    #expect(OpenCodePluginContent.tuiSource().contains("start=opencode;event=error"))
  }

  @Test(arguments: sources)
  func sourceDoesNotForwardNotifications(source: String) {
    // OpenCode's events carry no assistant text; the notify leg is
    // intentionally omitted, so no notify OSC should appear in the plugin.
    #expect(!source.contains("kind=notify"))
  }

  @Test(arguments: Entrypoint.allCases)
  func unreadablePluginIsNeitherAbsentNorClobbered(at entrypoint: Entrypoint) throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = OpenCodePluginInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.install()
    let url = entrypoint.url(in: installer)
    try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
    defer { try? fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }

    // An unreadable plugin is not an absent one, must not be overwritten
    // unchecked, and must not report a removal that never happened.
    #expect(throws: AgentFileUnreadableError.self) { try installer.installState() }
    #expect(throws: AgentFileUnreadableError.self) { try installer.install() }
    #expect(throws: AgentFileUnreadableError.self) { try installer.uninstall() }
    #expect(fileManager.fileExists(atPath: installer.serverPluginFileURL.path))
    #expect(fileManager.fileExists(atPath: installer.tuiPluginFileURL.path))
  }
}
