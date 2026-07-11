import Foundation
import Testing

// SocketDiscovery is compiled into this bundle from supacode-cli (a command
// line tool has no importable module); see the supacodeTests sources in
// Project.swift.
struct SocketDiscoveryTests {
  @Test func enclosingAppBundleFindsNearestAppAncestor() {
    let url = URL(fileURLWithPath: "/Applications/Supacode Dev.app/Contents/Resources/bin/supacode")
    #expect(SocketDiscovery.enclosingAppBundle(of: url)?.path == "/Applications/Supacode Dev.app")
  }

  @Test func enclosingAppBundleIsNilOutsideBundles() {
    let url = URL(fileURLWithPath: "/usr/local/bin/supacode")
    #expect(SocketDiscovery.enclosingAppBundle(of: url) == nil)
  }

  @Test func bareExecutableResolvesProdDirectory() {
    let url = URL(fileURLWithPath: "/usr/local/bin/supacode")
    #expect(SocketDiscovery.socketDirectory(executableURL: url, uid: 501) == "/tmp/supacode-501")
  }

  @Test func devBundleCLIResolvesDevDirectory() throws {
    let url = try Self.embeddedCLIURL(bundleIdentifier: "app.supabit.supacode.dev")
    #expect(SocketDiscovery.socketDirectory(executableURL: url, uid: 501) == "/tmp/supacode-dev-501")
  }

  @Test func prodBundleCLIResolvesProdDirectory() throws {
    let url = try Self.embeddedCLIURL(bundleIdentifier: "app.supabit.supacode")
    #expect(SocketDiscovery.socketDirectory(executableURL: url, uid: 501) == "/tmp/supacode-501")
  }

  @Test func symlinkedDevCLIResolvesDevDirectory() throws {
    let cliURL = try Self.embeddedCLIURL(bundleIdentifier: "app.supabit.supacode.dev")
    let linkURL = cliURL.deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "supacode-link")
    try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: cliURL)
    #expect(SocketDiscovery.socketDirectory(executableURL: linkURL, uid: 501) == "/tmp/supacode-dev-501")
  }

  /// Creates `<tmp>/<uuid>/Supacode.app/Contents/{Info.plist,Resources/bin/supacode}`
  /// and returns the embedded CLI's URL.
  private static func embeddedCLIURL(bundleIdentifier: String) throws -> URL {
    let bundleURL = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
      .appending(path: "Supacode.app", directoryHint: .isDirectory)
    let binDirectory = bundleURL.appending(path: "Contents/Resources/bin", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleIdentifier": bundleIdentifier]
    let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try plistData.write(to: bundleURL.appending(path: "Contents/Info.plist"))
    let cliURL = binDirectory.appending(path: "supacode")
    try Data().write(to: cliURL)
    return cliURL
  }
}
