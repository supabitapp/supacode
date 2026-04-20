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

  @Test func uninstallSkipsNonManagedExtension() throws {
    let home = try makeTempHome()
    let indexURL = extensionIndexURL(homeDirectoryURL: home)
    try FileManager.default.createDirectory(
      at: indexURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "// user's custom extension".write(to: indexURL, atomically: true, encoding: .utf8)

    let installer = makeInstaller(homeDirectoryURL: home)
    try installer.uninstall()

    // File should still exist because it's not Supacode-managed.
    #expect(FileManager.default.fileExists(atPath: indexURL.path(percentEncoded: false)))
  }

  @Test func uninstallNoOpWhenDirectoryDoesNotExist() throws {
    let home = try makeTempHome()
    let installer = makeInstaller(homeDirectoryURL: home)
    // Should not throw.
    try installer.uninstall()
  }

  @Test func installOverwritesExistingManagedExtension() throws {
    let home = try makeTempHome()
    let installer = makeInstaller(homeDirectoryURL: home)
    try installer.install()

    // Write again — should succeed and overwrite.
    try installer.install()
    #expect(installer.isInstalled())
  }
}
