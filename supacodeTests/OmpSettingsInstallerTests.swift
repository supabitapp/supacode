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

  private func makeInstaller(homeDirectoryURL: URL) -> PiSettingsInstaller {
    PiSettingsInstaller(agent: .omp, homeDirectoryURL: homeDirectoryURL)
  }

  private func extensionIndexURL(homeDirectoryURL: URL) -> URL {
    PiSettingsInstaller.extensionDirectoryURL(homeDirectoryURL: homeDirectoryURL, agent: .omp)
      .appending(path: "index.ts", directoryHint: .notDirectory)
  }

  // MARK: - Install / state round-trip.
  // omp reuses the pi file-write install with a nil binary probe, so these
  // mirror the pi suite but lock the divergent `.omp/agent` layout.

  @Test func installCreatesExtensionFileUnderOmpAgent() throws {
    let home = try makeTempHome()
    let installer = makeInstaller(homeDirectoryURL: home)
    try installer.install()

    let indexURL = extensionIndexURL(homeDirectoryURL: home)
    #expect(FileManager.default.fileExists(atPath: indexURL.path(percentEncoded: false)))
    // Lock the `.omp/agent/extensions/supacode` layout — the divergence from pi.
    #expect(indexURL.path(percentEncoded: false).contains(".omp/agent/extensions/supacode"))

    let contents = try String(contentsOf: indexURL, encoding: .utf8)
    #expect(contents.contains(PiExtensionContent.ownershipMarker))
    #expect(contents == PiExtensionContent.indexTs(for: .omp))
    #expect(installer.installState() == .installed)
  }

  @Test func uninstallRemovesManagedExtension() throws {
    let home = try makeTempHome()
    let installer = makeInstaller(homeDirectoryURL: home)
    try installer.install()
    #expect(installer.installState() == .installed)

    try installer.uninstall()
    #expect(installer.installState() == .notInstalled)

    let dirURL = PiSettingsInstaller.extensionDirectoryURL(homeDirectoryURL: home, agent: .omp)
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
    // The user's file and its directory must survive the guard.
    #expect(FileManager.default.fileExists(atPath: indexURL.path(percentEncoded: false)))
  }

  @Test func installCreatesFullDirectoryChainUnderOmp() throws {
    let home = try makeTempHome()
    // No `.omp` directory exists at all — install must create the whole chain.
    let ompDir = home.appending(path: ".omp", directoryHint: .isDirectory)
    #expect(!FileManager.default.fileExists(atPath: ompDir.path(percentEncoded: false)))

    let installer = makeInstaller(homeDirectoryURL: home)
    try installer.install()

    let dirURL = PiSettingsInstaller.extensionDirectoryURL(homeDirectoryURL: home, agent: .omp)
    #expect(dirURL.path(percentEncoded: false).contains(".omp/agent/extensions/supacode"))
    #expect(FileManager.default.fileExists(atPath: dirURL.path(percentEncoded: false)))
    #expect(installer.installState() == .installed)
  }

  // MARK: - Extension content divergence.

  @Test func ompExtensionEmitsOmpAgentID() {
    // Source-level proxy for the runtime `\x1b]3008;<action>=omp;…` OSC payload.
    let contents = PiExtensionContent.indexTs(for: .omp)
    #expect(contents.contains("const AGENT = \"omp\""))
    #expect(!contents.contains("const AGENT = \"pi\""))
    #expect(contents.contains("@oh-my-pi/pi-coding-agent"))
  }

  @Test func piExtensionStaysPiAfterParameterization() {
    // Byte-identity regression guard: parameterizing the shared template must
    // not change pi's emitted id, import package, or header.
    let contents = PiExtensionContent.indexTs(for: .pi)
    #expect(contents.contains("const AGENT = \"pi\""))
    #expect(contents.contains("@mariozechner/pi-coding-agent"))
    #expect(contents.contains("Supacode + Pi integration extension"))
  }

  // MARK: - Binary availability gate.

  @Test func installThrowsOmpUnavailableWhenBinaryMissing() async throws {
    let home = try makeTempHome()
    let installer = PiSettingsInstaller(agent: .omp, homeDirectoryURL: home, binaryProbe: { false })
    await #expect(throws: PiSettingsInstallerError.ompUnavailable) {
      try await installer.ensureBinaryAvailable()
    }
    // The gate must fire before any file is written.
    let indexURL = extensionIndexURL(homeDirectoryURL: home)
    #expect(!FileManager.default.fileExists(atPath: indexURL.path(percentEncoded: false)))
  }

  @Test func installProceedsWhenBinaryPresent() async throws {
    let home = try makeTempHome()
    let installer = PiSettingsInstaller(agent: .omp, homeDirectoryURL: home, binaryProbe: { true })
    try await installer.ensureBinaryAvailable()
    try installer.install()
    #expect(installer.installState() == .installed)
  }
}
