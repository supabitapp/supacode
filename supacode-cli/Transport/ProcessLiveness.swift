import Darwin
import Foundation

/// Liveness probe for the PIDs encoded in Supacode socket filenames.
nonisolated enum ProcessLiveness {
  /// Extracts the owning PID from a `pid-<pid>` socket filename. Rejects
  /// non-positive values: `kill(0, 0)` and `kill(-N, 0)` probe process groups.
  static func pid(fromSocketFilename filename: String) -> pid_t? {
    guard filename.hasPrefix("pid-"),
      let pid = pid_t(filename.dropFirst(4)),
      pid > 0
    else { return nil }
    return pid
  }

  /// Returns true when the process exists, even if it cannot be signaled.
  /// Sandboxes deny signaling the app with EPERM; only ESRCH proves the PID is
  /// gone. Mirrored in `AgentHookSocketServer.pruneStaleSocketFiles` and
  /// `AgentPresenceFeature.isAlive`; keep in sync.
  static func isRunning(_ pid: pid_t) -> Bool {
    let probeSucceeded = kill(pid, 0) == 0
    // Capture errno immediately so a future edit cannot clobber it first.
    let probeErrno = errno
    return probeSucceeded || probeErrno == EPERM
  }
}
