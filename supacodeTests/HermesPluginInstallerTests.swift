import Foundation
import Testing

@testable import SupacodeSettingsShared

struct HermesPluginInstallerTests {
  private let fileManager = FileManager.default

  private func makeTempHomeURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("supacode-hermes-plugin-\(UUID().uuidString)", isDirectory: true)
  }

  @Test func installWritesOnlyDurablePluginFiles() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = HermesPluginInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.install()

    #expect(
      try Set(fileManager.contentsOfDirectory(atPath: installer.pluginDirectoryURL.path)) == [
        "plugin.yaml", "__init__.py",
      ])
    #expect(try String(contentsOf: installer.manifestFileURL, encoding: .utf8) == HermesPluginContent.manifest())
    #expect(try String(contentsOf: installer.moduleFileURL, encoding: .utf8) == HermesPluginContent.module())
  }

  @Test func installStateTransitionsFromMissingToInstalled() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }
    let installer = HermesPluginInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)

    #expect(try installer.installState() == .notInstalled)
    try installer.install()
    #expect(try installer.installState() == .installed)
  }

  @Test func installStateOutdatedWhenOwnedModuleDiffers() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }
    let installer = HermesPluginInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try fileManager.createDirectory(at: installer.pluginDirectoryURL, withIntermediateDirectories: true)
    try HermesPluginContent.manifest().write(to: installer.manifestFileURL, atomically: true, encoding: .utf8)
    try "# \(HermesPluginContent.ownershipMarker)\n# old shape"
      .write(to: installer.moduleFileURL, atomically: true, encoding: .utf8)

    #expect(try installer.installState() == .outdated)
  }

  @Test func installStateNotInstalledForUnownedPluginWithSameName() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }
    let installer = HermesPluginInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try fileManager.createDirectory(at: installer.pluginDirectoryURL, withIntermediateDirectories: true)
    try "name: supacode-presence\n".write(to: installer.manifestFileURL, atomically: true, encoding: .utf8)
    try "def register(ctx):\n    pass\n".write(to: installer.moduleFileURL, atomically: true, encoding: .utf8)

    #expect(try installer.installState() == .notInstalled)
  }

  @Test func uninstallRemovesOwnedPluginDirectory() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }
    let installer = HermesPluginInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.install()

    try installer.uninstall()

    #expect(!fileManager.fileExists(atPath: installer.pluginDirectoryURL.path))
  }

  @Test func uninstallPreservesUnownedPluginDirectory() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }
    let installer = HermesPluginInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    let userModule = "def register(ctx):\n    pass\n"
    try fileManager.createDirectory(at: installer.pluginDirectoryURL, withIntermediateDirectories: true)
    try "name: supacode-presence\n".write(to: installer.manifestFileURL, atomically: true, encoding: .utf8)
    try userModule.write(to: installer.moduleFileURL, atomically: true, encoding: .utf8)

    try installer.uninstall()

    #expect(try String(contentsOf: installer.moduleFileURL, encoding: .utf8) == userModule)
  }

  @Test func pluginPathMatchesHermesPluginDirectory() {
    let homeURL = URL(fileURLWithPath: "/Users/test")
    let installer = HermesPluginInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    #expect(installer.pluginDirectoryURL.path == "/Users/test/.hermes/plugins/supacode-presence")
  }

  @Test func generatedModuleUsesHermesAgentAndNoLocalTransientPaths() {
    let module = HermesPluginContent.module()

    #expect(module.contains("AGENT = \"hermes\""))
    #expect(module.contains("ctx.register_hook(\"on_session_start\""))
    #expect(module.contains("ctx.register_hook(\"pre_llm_call\""))
    #expect(module.contains("ctx.register_hook(\"transform_llm_output\""))
    #expect(module.contains("ctx.register_hook(\"on_session_end\""))
    #expect(!module.contains("/Users/"))
    #expect(!module.contains("debug.log"))
    #expect(!module.contains("__pycache__"))
    #expect(!module.contains("SUPACODE_PRESENCE_DEBUG"))
  }

  @Test func installRefusesToOverwriteUnownedPlugin() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }
    let installer = HermesPluginInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    let userManifest = "name: supacode-presence\n"
    let userModule = "def register(ctx):\n    pass\n"
    try fileManager.createDirectory(at: installer.pluginDirectoryURL, withIntermediateDirectories: true)
    try userManifest.write(to: installer.manifestFileURL, atomically: true, encoding: .utf8)
    try userModule.write(to: installer.moduleFileURL, atomically: true, encoding: .utf8)

    #expect(throws: HermesPluginInstallerError.self) { try installer.install() }
    #expect(try String(contentsOf: installer.manifestFileURL, encoding: .utf8) == userManifest)
    #expect(try String(contentsOf: installer.moduleFileURL, encoding: .utf8) == userModule)
  }

  @Test func moduleEmitsValidHookEventPresenceStates() {
    let module = HermesPluginContent.module()

    // Every presence state the module emits must round-trip through `HookEvent`,
    // or the app's `AgentPresenceOSC.parse` drops the signal.
    for state in ["session_start", "busy", "idle"] {
      #expect(module.contains("_emit_presence(\"\(state)\")"))
      #expect(HookEvent(rawValue: state) != nil)
    }
    #expect(!module.contains("_emit_presence(\"session_end\")"))
  }

  @Test func onSessionEndEmitsIdleBetweenTurns() {
    let module = HermesPluginContent.module()

    // Hermes fires `on_session_end` per turn, so its hook must emit `idle` (not
    // `session_end`) to keep the badge present between turns. `_on_session_end` is
    // the last function, so its body runs to the end of the module.
    guard let hook = module.range(of: "def _on_session_end") else {
      Issue.record("module is missing the _on_session_end hook")
      return
    }
    let body = module[hook.upperBound...]
    #expect(body.contains("_emit_presence(\"idle\")"))
    #expect(!body.contains("_emit_presence(\"session_end\")"))
  }

  @Test func installOverOutdatedReturnsInstalled() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }
    let installer = HermesPluginInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try fileManager.createDirectory(at: installer.pluginDirectoryURL, withIntermediateDirectories: true)
    try HermesPluginContent.manifest().write(to: installer.manifestFileURL, atomically: true, encoding: .utf8)
    try "# \(HermesPluginContent.ownershipMarker)\n# old shape"
      .write(to: installer.moduleFileURL, atomically: true, encoding: .utf8)
    #expect(try installer.installState() == .outdated)

    try installer.install()

    #expect(try installer.installState() == .installed)
    #expect(try String(contentsOf: installer.moduleFileURL, encoding: .utf8) == HermesPluginContent.module())
  }

  @Test func installIsIdempotent() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }
    let installer = HermesPluginInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)

    try installer.install()
    let first = try Data(contentsOf: installer.moduleFileURL)
    try installer.install()
    let second = try Data(contentsOf: installer.moduleFileURL)

    #expect(first == second)
  }

  @Test func uninstallIsNoOpWhenMissing() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }
    let installer = HermesPluginInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)

    try installer.uninstall()

    #expect(!fileManager.fileExists(atPath: installer.pluginDirectoryURL.path))
  }

  @Test func unreadableModuleIsNeitherAbsentNorClobbered() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = HermesPluginInstaller(homeDirectoryURL: homeURL, fileManager: fileManager)
    try installer.install()
    try fileManager.setAttributes(
      [.posixPermissions: 0o000], ofItemAtPath: installer.moduleFileURL.path)
    defer {
      try? fileManager.setAttributes(
        [.posixPermissions: 0o644], ofItemAtPath: installer.moduleFileURL.path)
    }

    // An unreadable module is not an absent one, must not be overwritten
    // unchecked, and must not report a removal that never happened.
    #expect(throws: AgentFileUnreadableError.self) { try installer.installState() }
    #expect(throws: AgentFileUnreadableError.self) { try installer.install() }
    #expect(throws: AgentFileUnreadableError.self) { try installer.uninstall() }
    #expect(fileManager.fileExists(atPath: installer.moduleFileURL.path))
  }
}
