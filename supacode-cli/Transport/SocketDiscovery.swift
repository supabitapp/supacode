import Darwin
import Foundation

/// Discovers Supacode socket paths.
nonisolated enum SocketDiscovery {
  /// Returns the socket path from `$SUPACODE_SOCKET_PATH`.
  /// Only available inside a Supacode terminal session.
  static func fromEnvironment() -> String? {
    EnvironmentDefaults.socketPath
  }

  /// The nearest ancestor `.app` bundle containing `url`, if any.
  static func enclosingAppBundle(of url: URL) -> URL? {
    var url = url.standardizedFileURL.deletingLastPathComponent()
    while url.path != "/" {
      if url.pathExtension == "app" { return url }
      url.deleteLastPathComponent()
    }
    return nil
  }

  /// True when the executable at `executableURL` is embedded in a dev (`….dev`)
  /// app bundle. The CLI binary is shared between the prod and dev app targets,
  /// so dev-ness is derived at runtime from the binary's own location rather
  /// than a compile flag.
  static func isDevelopmentBuild(executableURL: URL) -> Bool {
    guard let bundleURL = enclosingAppBundle(of: executableURL.resolvingSymlinksInPath()) else { return false }
    return Bundle(url: bundleURL)?.bundleIdentifier?.hasSuffix(".dev") ?? false
  }

  /// The socket directory for the build this CLI is embedded in. Must mirror
  /// the directory `AgentHookSocketServer` binds, so each build's CLI only
  /// discovers its own app.
  static func socketDirectory(executableURL: URL, uid: uid_t) -> String {
    isDevelopmentBuild(executableURL: executableURL) ? "/tmp/supacode-dev-\(uid)" : "/tmp/supacode-\(uid)"
  }

  static var socketDirectory: String {
    socketDirectory(executableURL: Bundle.main.executableURL ?? URL(fileURLWithPath: "/"), uid: getuid())
  }

  /// Returns true if the socket path looks like a live Supacode socket
  /// (i.e. the owning PID is still running).
  static func isAlive(_ path: String) -> Bool {
    let filename = URL(fileURLWithPath: path).lastPathComponent
    guard filename.hasPrefix("pid-"),
      let pid = Int32(filename.dropFirst(4))
    else { return false }
    return kill(pid, 0) == 0
  }

  /// Lists all live Supacode sockets in this build's socket directory.
  /// Throws when the directory exists but cannot be read (e.g. permission denied).
  static func listAll() throws -> [String] {
    let directory = socketDirectory
    let entries: [String]
    do {
      entries = try FileManager.default.contentsOfDirectory(atPath: directory)
    } catch {
      let nsError = error as NSError
      guard nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoSuchFileError else { throw error }
      return []
    }
    return entries.compactMap { entry in
      guard entry.hasPrefix("pid-"),
        let pid = Int32(entry.dropFirst(4)),
        kill(pid, 0) == 0
      else { return nil }
      return "\(directory)/\(entry)"
    }
  }
}
