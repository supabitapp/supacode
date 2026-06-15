import Darwin
import Foundation

/// Discovers tty7 socket paths.
nonisolated enum SocketDiscovery {
  /// Returns the socket path from `$TTY7_SOCKET_PATH`.
  /// Only available inside a tty7 terminal session.
  static func fromEnvironment() -> String? {
    EnvironmentDefaults.socketPath
  }

  /// Returns true if the socket path looks like a live tty7 socket
  /// (i.e. the owning PID is still running).
  static func isAlive(_ path: String) -> Bool {
    let filename = URL(fileURLWithPath: path).lastPathComponent
    guard filename.hasPrefix("pid-"),
      let pid = Int32(filename.dropFirst(4))
    else { return false }
    return kill(pid, 0) == 0
  }

  /// Lists all live tty7 sockets in `/tmp/tty7-<uid>/`.
  /// Throws when the directory exists but cannot be read (e.g. permission denied).
  static func listAll() throws -> [String] {
    let uid = getuid()
    let directory = "/tmp/tty7-\(uid)"
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
