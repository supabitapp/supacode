import Foundation
import Testing

@testable import SupacodeSettingsShared

struct PiSettingsInstallerTests {
  private func makeTempHome() throws -> URL {
    let tempDir = FileManager.default.temporaryDirectory
      .appending(path: "PiSettingsInstallerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    return tempDir
  }

  private func makeInstaller(homeDirectoryURL: URL) -> PiSettingsInstaller {
    PiSettingsInstaller(homeDirectoryURL: homeDirectoryURL)
  }

  private func extensionIndexURL(homeDirectoryURL: URL) -> URL {
    PiSettingsInstaller.extensionDirectoryURL(homeDirectoryURL: homeDirectoryURL)
      .appending(path: "index.ts", directoryHint: .notDirectory)
  }

  @Test func isInstalledReturnsFalseWhenNoFileExists() throws {
    let home = try makeTempHome()
    let installer = makeInstaller(homeDirectoryURL: home)
    #expect(!installer.isInstalled())
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
    #expect(!installer.isInstalled())
  }

  @Test func isInstalledReturnsFalseForPartialMarker() throws {
    let home = try makeTempHome()
    let indexURL = extensionIndexURL(homeDirectoryURL: home)
    try FileManager.default.createDirectory(
      at: indexURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    // Partial marker must not match — full-string containment is the contract.
    try "/* supacode-managed".write(to: indexURL, atomically: true, encoding: .utf8)

    let installer = makeInstaller(homeDirectoryURL: home)
    #expect(!installer.isInstalled())
  }

  @Test func isInstalledReturnsFalseWhenFileIsUnreadableAsUTF8() throws {
    let home = try makeTempHome()
    let indexURL = extensionIndexURL(homeDirectoryURL: home)
    try FileManager.default.createDirectory(
      at: indexURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    // Lead bytes that are invalid UTF-8 — read should fail, not be confused
    // with an installed/uninstalled state.
    try Data([0xFF, 0xFE, 0xFD, 0x00]).write(to: indexURL)

    let installer = makeInstaller(homeDirectoryURL: home)
    #expect(!installer.isInstalled())
  }

  @Test func isInstalledReturnsTrueWhenMarkerPresent() throws {
    let home = try makeTempHome()
    let installer = makeInstaller(homeDirectoryURL: home)
    try installer.install()
    #expect(installer.isInstalled())
  }

  @Test func installCreatesExtensionFile() throws {
    let home = try makeTempHome()
    let installer = makeInstaller(homeDirectoryURL: home)
    try installer.install()

    let indexURL = extensionIndexURL(homeDirectoryURL: home)
    #expect(FileManager.default.fileExists(atPath: indexURL.path(percentEncoded: false)))

    let contents = try String(contentsOf: indexURL, encoding: .utf8)
    #expect(contents.contains(PiExtensionContent.ownershipMarker))
    #expect(contents.contains("agent_start"))
    #expect(contents.contains("agent_end"))
    #expect(contents.contains("session_shutdown"))
  }

  @Test func uninstallRemovesManagedExtension() throws {
    let home = try makeTempHome()
    let installer = makeInstaller(homeDirectoryURL: home)
    try installer.install()
    #expect(installer.isInstalled())

    try installer.uninstall()
    #expect(!installer.isInstalled())

    let dirURL = PiSettingsInstaller.extensionDirectoryURL(homeDirectoryURL: home)
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
    #expect(throws: PiSettingsInstallerError.extensionNotManaged) {
      try installer.uninstall()
    }
    // Neither the file nor the enclosing directory may be touched when
    // the guard fires — a user could be keeping siblings alongside it.
    #expect(FileManager.default.fileExists(atPath: indexURL.path(percentEncoded: false)))
    let dirURL = PiSettingsInstaller.extensionDirectoryURL(homeDirectoryURL: home)
    #expect(FileManager.default.fileExists(atPath: dirURL.path(percentEncoded: false)))
  }

  @Test func uninstallNoOpWhenDirectoryDoesNotExist() throws {
    let home = try makeTempHome()
    let installer = makeInstaller(homeDirectoryURL: home)
    // Already uninstalled — silent no-op.
    try installer.uninstall()
  }

  @Test func uninstallRemovesEmptyDirectoryWhenIndexMissing() throws {
    let home = try makeTempHome()
    let dirURL = PiSettingsInstaller.extensionDirectoryURL(homeDirectoryURL: home)
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
    // Seed a stale managed file — marker present but body drifted from
    // the current bundle. Install must rewrite the full canonical body.
    let staleBody = "\(PiExtensionContent.ownershipMarker)\n// stale body"
    try staleBody.write(to: indexURL, atomically: true, encoding: .utf8)

    let installer = makeInstaller(homeDirectoryURL: home)
    try installer.install()

    let contents = try String(contentsOf: indexURL, encoding: .utf8)
    #expect(contents == PiExtensionContent.indexTs)
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
    #expect(throws: PiSettingsInstallerError.extensionNotManaged) {
      try installer.install()
    }
    // User's file must be preserved byte-for-byte.
    let contents = try String(contentsOf: indexURL, encoding: .utf8)
    #expect(contents == "// user's custom extension")
  }

  @Test func installCreatesFullDirectoryChainWhenMissing() throws {
    let home = try makeTempHome()
    // No `.pi` directory exists at all — install must create the whole chain.
    let piDir = home.appending(path: ".pi", directoryHint: .isDirectory)
    #expect(!FileManager.default.fileExists(atPath: piDir.path(percentEncoded: false)))

    let installer = makeInstaller(homeDirectoryURL: home)
    try installer.install()

    // Lock the `.pi/agent/extensions/<name>` layout — a reshuffle of the
    // managed paths would otherwise slip past `isInstalled()`.
    let dirURL = PiSettingsInstaller.extensionDirectoryURL(homeDirectoryURL: home)
    #expect(FileManager.default.fileExists(atPath: dirURL.path(percentEncoded: false)))
    #expect(installer.isInstalled())
  }
}
