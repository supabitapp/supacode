import Foundation

/// Typed accessors for tty7 environment variables injected into terminal sessions.
nonisolated enum EnvironmentDefaults {
  static var socketPath: String? {
    ProcessInfo.processInfo.environment["TTY7_SOCKET_PATH"]
  }

  /// Already percent-encoded by the host app.
  static var worktreeID: String? {
    ProcessInfo.processInfo.environment["TTY7_WORKTREE_ID"]
  }

  static var tabID: String? {
    ProcessInfo.processInfo.environment["TTY7_TAB_ID"]
  }

  static var surfaceID: String? {
    ProcessInfo.processInfo.environment["TTY7_SURFACE_ID"]
  }

  /// Already percent-encoded by the host app.
  static var repoID: String? {
    ProcessInfo.processInfo.environment["TTY7_REPO_ID"]
  }
}
