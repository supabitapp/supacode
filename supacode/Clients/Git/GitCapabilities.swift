import Foundation

/// Detects (once) whether the active `git` supports built-in `core.fsmonitor`
/// (git >= 2.37). Older git interprets `core.fsmonitor=true` as a hook path and
/// errors, so the flag must be gated on this check.
actor GitCapabilities {
  static let shared = GitCapabilities()

  private let shell: ShellClient
  private var cachedFsmonitorSupport: Bool?

  init(shell: ShellClient = .live) {
    self.shell = shell
  }

  func supportsFsmonitor() async -> Bool {
    if let cachedFsmonitorSupport {
      return cachedFsmonitorSupport
    }
    let env = URL(fileURLWithPath: "/usr/bin/env")
    let output = try? await shell.run(env, ["git", "--version"], nil).stdout
    let supported = Self.parseFsmonitorSupport(fromVersionOutput: output ?? "")
    cachedFsmonitorSupport = supported
    return supported
  }

  /// Parses `git version X.Y.Z` and returns true when (X, Y) >= (2, 37).
  nonisolated static func parseFsmonitorSupport(fromVersionOutput output: String) -> Bool {
    guard let match = output.firstMatch(of: /git version (\d+)\.(\d+)/) else {
      return false
    }
    let major = Int(match.1) ?? 0
    let minor = Int(match.2) ?? 0
    return (major, minor) >= (2, 37)
  }
}
