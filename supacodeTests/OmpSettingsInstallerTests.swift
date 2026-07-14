import Foundation
import Testing

@testable import SupacodeSettingsShared

struct OmpSettingsInstallerTests {
  private func makeTempHome() throws -> URL {
    let tempDir = FileManager.default.temporaryDirectory
      .appending(path: "OmpSettingsInstallerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    return tempDir
  }

  private func makeInstaller(homeDirectoryURL: URL) -> OmpSettingsInstaller {
    OmpSettingsInstaller(homeDirectoryURL: homeDirectoryURL)
  }

  private func extensionIndexURL(homeDirectoryURL: URL) -> URL {
    OmpSettingsInstaller.extensionDirectoryURL(homeDirectoryURL: homeDirectoryURL)
      .appending(path: "index.ts", directoryHint: .notDirectory)
  }

  @Test func isInstalledReturnsFalseWhenNoFileExists() throws {
    let home = try makeTempHome()
    let installer = makeInstaller(homeDirectoryURL: home)
    #expect(installer.installState() == .notInstalled)
  }

  @Test func isInstalledReturnsFalseWhenFileExistsWithoutMarker() throws {
    let home = try makeTempHome()
    let indexURL = extensionIndexURL(homeDirectoryURL: home)
    try FileManager.default.createDirectory(
      at: indexURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "// some other extension".write(to: indexURL, atomically: true, encoding: .utf8)

    let installer = makeInstaller(homeDirectoryURL: home)
    #expect(installer.installState() == .notInstalled)
  }

  @Test func isInstalledReturnsFalseForPartialMarker() throws {
    let home = try makeTempHome()
    let indexURL = extensionIndexURL(homeDirectoryURL: home)
    try FileManager.default.createDirectory(
      at: indexURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    // Partial marker must not match: full-string containment is the contract.
    try "/* supacode-managed".write(to: indexURL, atomically: true, encoding: .utf8)

    let installer = makeInstaller(homeDirectoryURL: home)
    #expect(installer.installState() == .notInstalled)
  }

  @Test func isInstalledReturnsFalseWhenFileIsUnreadableAsUTF8() throws {
    let home = try makeTempHome()
    let indexURL = extensionIndexURL(homeDirectoryURL: home)
    try FileManager.default.createDirectory(
      at: indexURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    // Lead bytes that are invalid UTF-8: an unreadable file resolves to
    // not-installed rather than crashing or false-positiving as installed.
    try Data([0xFF, 0xFE, 0xFD, 0x00]).write(to: indexURL)

    let installer = makeInstaller(homeDirectoryURL: home)
    #expect(installer.installState() == .notInstalled)
  }

  @Test func isInstalledReturnsTrueWhenMarkerPresent() throws {
    let home = try makeTempHome()
    let installer = makeInstaller(homeDirectoryURL: home)
    try installer.install()
    #expect(installer.installState() == .installed)
  }

  @Test func installStateReturnsOutdatedWhenManagedBodyDrifted() throws {
    let home = try makeTempHome()
    let indexURL = extensionIndexURL(homeDirectoryURL: home)
    try FileManager.default.createDirectory(
      at: indexURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    // Marker present but body drifted from the current bundle: an older
    // Supacode wrote this, so the user must get the Update affordance.
    try "\(OmpExtensionContent.ownershipMarker)\n// stale body".write(
      to: indexURL, atomically: true, encoding: .utf8)

    #expect(makeInstaller(homeDirectoryURL: home).installState() == .outdated)
  }

  @Test func ompEmittedLifecycleEventsKeepProcessPresence() {
    // OMP loads the extension into in-process subagent sessions. A subagent
    // shutdown shares the top-level process pid, so emitting session_end would
    // remove the main OMP badge. Process liveness owns final badge removal.
    for event in ["session_start", "busy", "idle"] {
      #expect(OmpExtensionContent.indexTs.contains("emitPresence(\"\(event)\")"))
      let signal = AgentPresenceOSC.parse(id: "omp", metadata: "event=\(event)")
      #expect(signal?.agent == "omp")
      #expect(signal?.eventRawValue == event)
    }
    #expect(!OmpExtensionContent.indexTs.contains("emitPresence(\"session_end\")"))
  }

  @Test func installCreatesExtensionFile() throws {
    let home = try makeTempHome()
    let installer = makeInstaller(homeDirectoryURL: home)
    try installer.install()

    let indexURL = extensionIndexURL(homeDirectoryURL: home)
    #expect(FileManager.default.fileExists(atPath: indexURL.path(percentEncoded: false)))

    let contents = try String(contentsOf: indexURL, encoding: .utf8)
    #expect(contents.contains(OmpExtensionContent.ownershipMarker))
    #expect(contents.contains("Supacode + Oh My Pi integration extension."))
    #expect(contents.contains("@oh-my-pi/pi-coding-agent"))
    #expect(contents.contains("const AGENT = \"omp\""))
  }
  @Test func installWritesExpectedOsc3008LifecycleWireStrings() throws {
    let home = try makeTempHome()
    let installer = makeInstaller(homeDirectoryURL: home)
    try installer.install()

    let contents = try String(contentsOf: extensionIndexURL(homeDirectoryURL: home), encoding: .utf8)
    let expectedSnippets = [
      "event=${event}${localPidSuffix()}",
      #"\x1b]3008;${action}=${AGENT};${meta}\x1b\\"#,
      "kind=notify",
      "agent_start",
      "agent_end",
      "session_shutdown",
    ]

    for snippet in expectedSnippets {
      #expect(contents.contains(snippet))
    }
  }

  @Test func uninstallRemovesManagedExtension() throws {
    let home = try makeTempHome()
    let installer = makeInstaller(homeDirectoryURL: home)
    try installer.install()
    #expect(installer.installState() == .installed)

    try installer.uninstall()
    #expect(installer.installState() == .notInstalled)

    let dirURL = OmpSettingsInstaller.extensionDirectoryURL(homeDirectoryURL: home)
    #expect(!FileManager.default.fileExists(atPath: dirURL.path(percentEncoded: false)))
  }

  @Test func uninstallThrowsExtensionNotManagedWhenFileIsUserAuthored() throws {
    let home = try makeTempHome()
    let indexURL = extensionIndexURL(homeDirectoryURL: home)
    try FileManager.default.createDirectory(
      at: indexURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "// user's custom extension".write(to: indexURL, atomically: true, encoding: .utf8)

    let installer = makeInstaller(homeDirectoryURL: home)
    #expect(throws: OmpSettingsInstallerError.extensionNotManaged) {
      try installer.uninstall()
    }
    // Neither the file nor the enclosing directory may be touched when
    // the guard fires: a user could be keeping siblings alongside it.
    #expect(FileManager.default.fileExists(atPath: indexURL.path(percentEncoded: false)))
    let dirURL = OmpSettingsInstaller.extensionDirectoryURL(homeDirectoryURL: home)
    #expect(FileManager.default.fileExists(atPath: dirURL.path(percentEncoded: false)))
  }

  @Test func uninstallNoOpWhenDirectoryDoesNotExist() throws {
    let home = try makeTempHome()
    let installer = makeInstaller(homeDirectoryURL: home)
    // Already uninstalled: silent no-op.
    try installer.uninstall()
  }

  @Test func uninstallRemovesEmptyDirectoryWhenIndexMissing() throws {
    let home = try makeTempHome()
    let dirURL = OmpSettingsInstaller.extensionDirectoryURL(homeDirectoryURL: home)
    try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

    let installer = makeInstaller(homeDirectoryURL: home)
    try installer.uninstall()

    #expect(!FileManager.default.fileExists(atPath: dirURL.path(percentEncoded: false)))
  }

  @Test func installOverwritesExistingManagedExtension() throws {
    let home = try makeTempHome()
    let indexURL = extensionIndexURL(homeDirectoryURL: home)
    try FileManager.default.createDirectory(
      at: indexURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    // Seed a stale managed file: marker present but body drifted from
    // the current bundle. Install must rewrite the full canonical body.
    let staleBody = "\(OmpExtensionContent.ownershipMarker)\n// stale body"
    try staleBody.write(to: indexURL, atomically: true, encoding: .utf8)

    let installer = makeInstaller(homeDirectoryURL: home)
    try installer.install()

    let contents = try String(contentsOf: indexURL, encoding: .utf8)
    #expect(contents == OmpExtensionContent.indexTs)
  }

  @Test func installThrowsExtensionNotManagedWhenFileIsUserAuthored() throws {
    let home = try makeTempHome()
    let indexURL = extensionIndexURL(homeDirectoryURL: home)
    try FileManager.default.createDirectory(
      at: indexURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "// user's custom extension".write(to: indexURL, atomically: true, encoding: .utf8)

    let installer = makeInstaller(homeDirectoryURL: home)
    #expect(throws: OmpSettingsInstallerError.extensionNotManaged) {
      try installer.install()
    }
    // User's file must be preserved byte-for-byte.
    let contents = try String(contentsOf: indexURL, encoding: .utf8)
    #expect(contents == "// user's custom extension")
  }

  @Test func installCreatesFullDirectoryChainWhenMissing() throws {
    let home = try makeTempHome()
    // No `.omp` directory exists at all: install must create the whole chain.
    let ompDir = home.appending(path: ".omp", directoryHint: .isDirectory)
    #expect(!FileManager.default.fileExists(atPath: ompDir.path(percentEncoded: false)))

    let installer = makeInstaller(homeDirectoryURL: home)
    try installer.install()

    // Lock the `.omp/agent/extensions/<name>` layout: a reshuffle of the
    // managed paths would otherwise slip past `installState()`.
    let dirURL = OmpSettingsInstaller.extensionDirectoryURL(homeDirectoryURL: home)
    #expect(FileManager.default.fileExists(atPath: dirURL.path(percentEncoded: false)))
    #expect(installer.installState() == .installed)
  }

  @Test func extensionDirectoryURLUsesOmpAgentSiblingPath() {
    let home = URL(fileURLWithPath: "/Users/test")
    let url = OmpSettingsInstaller.extensionDirectoryURL(homeDirectoryURL: home)
    #expect(url.path == "/Users/test/.omp/agent/extensions/supacode")
  }
}
