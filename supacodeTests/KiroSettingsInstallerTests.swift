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

  private func makeInstaller(
    homeURL: URL,
    versionOutput: String = "kiro 1.0.0",
    versionStatus: Int32 = 0,
    versionError: Error? = nil
  ) -> KiroSettingsInstaller {
    KiroSettingsInstaller(
      homeDirectoryURL: homeURL,
      fileManager: fileManager,
      runKiroVersionCommand: {
        if let versionError { throw versionError }
        return .init(status: versionStatus, standardOutput: versionOutput, standardError: "")
      },
    )
  }

  @Test func installProgressHooksCreatesDefaultConfigWhenMissing() async throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = makeInstaller(homeURL: homeURL)
    try await installer.installProgressHooks()

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

  @Test func installNotificationHooksCreatesDefaultConfigWhenMissing() async throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = makeInstaller(homeURL: homeURL)
    try await installer.installNotificationHooks()

    let settingsURL = KiroSettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    let data = try Data(contentsOf: settingsURL)
    let json = try JSONDecoder().decode(JSONValue.self, from: data)
    let root = try #require(json.objectValue)
    #expect(root["name"] == .string("kiro_default"))
    #expect(root["tools"] == .array([.string("*")]))
  }

  @Test func installProgressHooksDoesNotOverwriteExistingConfig() async throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = makeInstaller(homeURL: homeURL)
    try await installer.installProgressHooks()

    let settingsURL = KiroSettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    let firstWrite = try Data(contentsOf: settingsURL)

    try await installer.installProgressHooks()
    let secondWrite = try Data(contentsOf: settingsURL)

    #expect(firstWrite == secondWrite)
  }

  @Test func installPreservesExistingConfigWithoutHooksSection() async throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    // Simulate a user-authored kiro_default.json that has custom `tools` and
    // `resources` but no `hooks` key yet — install must merge hooks in place
    // without stomping the user's fields.
    let settingsURL = KiroSettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    try fileManager.createDirectory(
      at: settingsURL.deletingLastPathComponent(),
      withIntermediateDirectories: true,
    )
    let userConfig: [String: JSONValue] = [
      "name": .string("kiro_default"),
      "tools": .array([.string("filesystem"), .string("web")]),
      "resources": .array([.string("file://custom.md")]),
    ]
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(JSONValue.object(userConfig)).write(to: settingsURL)

    let installer = makeInstaller(homeURL: homeURL)
    try await installer.installProgressHooks()

    let data = try Data(contentsOf: settingsURL)
    let root = try #require(
      try JSONDecoder().decode(JSONValue.self, from: data).objectValue)
    #expect(root["tools"] == .array([.string("filesystem"), .string("web")]))
    #expect(root["resources"] == .array([.string("file://custom.md")]))
    #expect(root["hooks"]?.objectValue != nil)
  }

  @Test func uninstallProgressHooksIsNoOpWhenFileMissing() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = makeInstaller(homeURL: homeURL)
    #expect(throws: Never.self) {
      try installer.uninstallProgressHooks()
    }
  }

  @Test func uninstallNotificationHooksIsNoOpWhenFileMissing() throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = makeInstaller(homeURL: homeURL)
    #expect(throws: Never.self) {
      try installer.uninstallNotificationHooks()
    }
  }

  @Test func isInstalledProgressReturnsFalseBeforeInstall() {
    let homeURL = makeTempHomeURL()
    let installer = makeInstaller(homeURL: homeURL)
    #expect(installer.isInstalled(progress: true) == false)
  }

  @Test func isInstalledProgressReturnsTrueAfterInstall() async throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = makeInstaller(homeURL: homeURL)
    try await installer.installProgressHooks()
    #expect(installer.isInstalled(progress: true) == true)
  }

  @Test func isInstalledNotificationsReturnsTrueAfterInstall() async throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = makeInstaller(homeURL: homeURL)
    try await installer.installNotificationHooks()
    #expect(installer.isInstalled(progress: false) == true)
  }

  @Test func isInstalledProgressReturnsFalseAfterUninstall() async throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = makeInstaller(homeURL: homeURL)
    try await installer.installProgressHooks()
    try installer.uninstallProgressHooks()
    #expect(installer.isInstalled(progress: true) == false)
  }

  @Test func settingsURLPointsToExpectedPath() {
    let homeURL = URL(fileURLWithPath: "/Users/test")
    let url = KiroSettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    #expect(url.path == "/Users/test/.kiro/agents/kiro_default.json")
  }

  // MARK: - Version gating.

  @Test func installFailsWhenKiroBinaryMissing() async {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = makeInstaller(homeURL: homeURL, versionStatus: 127)
    await #expect(throws: KiroSettingsInstallerError.kiroUnavailable) {
      try await installer.installProgressHooks()
    }
    let settingsURL = KiroSettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    #expect(fileManager.fileExists(atPath: settingsURL.path) == false)
  }

  @Test func installFailsWhenKiroCommandThrows() async {
    struct Boom: Error {}
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = makeInstaller(homeURL: homeURL, versionError: Boom())
    await #expect(throws: KiroSettingsInstallerError.kiroUnavailable) {
      try await installer.installProgressHooks()
    }
  }

  @Test func installFailsOnUnsupportedKiroVersion() async {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = makeInstaller(homeURL: homeURL, versionOutput: "kiro 2.0.0")
    await #expect(throws: KiroSettingsInstallerError.unsupportedKiroVersion("2.0.0")) {
      try await installer.installProgressHooks()
    }
  }

  @Test func installFailsWhenVersionOutputHasNoVersionNumber() async {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = makeInstaller(homeURL: homeURL, versionOutput: "nothing to see here")
    await #expect(
      throws: KiroSettingsInstallerError.unsupportedKiroVersion("nothing to see here")
    ) {
      try await installer.installProgressHooks()
    }
  }

  @Test func installFailsOnNonZeroNonMissingStatus() async {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = makeInstaller(
      homeURL: homeURL,
      versionOutput: "",
      versionStatus: 1,
    )
    await #expect(
      throws: KiroSettingsInstallerError.unsupportedKiroVersion("exit status 1")
    ) {
      try await installer.installProgressHooks()
    }
  }

  @Test func installFailsForDoubleDigitMajorVersion() async {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = makeInstaller(homeURL: homeURL, versionOutput: "kiro 10.0.0")
    await #expect(
      throws: KiroSettingsInstallerError.unsupportedKiroVersion("10.0.0")
    ) {
      try await installer.installProgressHooks()
    }
  }

  @Test func installSucceedsWhenStderrBannerPrecedesStdoutVersion() async throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    // Login shells can print their own banners to stderr; parsing must prefer
    // stdout so a stderr "Python 3.11" banner does not reject valid Kiro 1.x.
    let installer = KiroSettingsInstaller(
      homeDirectoryURL: homeURL,
      fileManager: fileManager,
      runKiroVersionCommand: {
        .init(
          status: 0,
          standardOutput: "kiro 1.2.3\n",
          standardError: "Python 3.11.0 (banner)",
        )
      },
    )
    try await installer.installProgressHooks()
    let settingsURL = KiroSettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    #expect(fileManager.fileExists(atPath: settingsURL.path))
  }

  @Test func installSkipsVersionCheckWhenFileAlreadyExists() async throws {
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }

    // Seed the file so ensureDefaultAgentConfig short-circuits.
    let settingsURL = KiroSettingsInstaller.settingsURL(homeDirectoryURL: homeURL)
    try fileManager.createDirectory(
      at: settingsURL.deletingLastPathComponent(),
      withIntermediateDirectories: true,
    )
    let seeded: [String: JSONValue] = ["name": .string("kiro_default")]
    try JSONEncoder().encode(JSONValue.object(seeded)).write(to: settingsURL)

    // Version command would fail if invoked — test that install still succeeds.
    let installer = makeInstaller(homeURL: homeURL, versionStatus: 127)
    try await installer.installProgressHooks()
    #expect(fileManager.fileExists(atPath: settingsURL.path))
  }

  @Test func extractVersionHandlesCommonFormats() {
    #expect(KiroSettingsInstaller.extractVersion(from: "kiro 1.2.3") == "1.2.3")
    #expect(KiroSettingsInstaller.extractVersion(from: "Kiro CLI v1.0.0 (build abcd)") == "1.0.0")
    #expect(KiroSettingsInstaller.extractVersion(from: "1.4") == "1.4")
    #expect(KiroSettingsInstaller.extractVersion(from: "no version here") == nil)
    #expect(KiroSettingsInstaller.extractVersion(from: "just 42") == nil)
  }
}
