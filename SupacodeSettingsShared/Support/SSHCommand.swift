import Foundation

/// Pure, stateless builders for the `ssh` command lines Supacode issues against
/// a `RemoteHost`. Two consumers, two shapes:
///
///   - `invocation(...)` returns an argv for `Process` / `ShellClient`: ssh
///     receives the remote command as a single argument, so only the *remote*
///     shell re-parses it (one quoting level, applied in `remoteCommand`).
///   - `commandLine(...)` returns a single string for a parent `/bin/sh -c`
///     (Ghostty's surface command), so the remote command must additionally be
///     quoted for the *local* shell (two quoting levels).
///
/// Every invocation shares `controlOptions` so N git calls plus the terminal
/// reuse one multiplexed SSH connection: one auth / FIDO touch, and no
/// per-call TCP+handshake round trip that would otherwise make a many-worktree
/// sidebar crawl.
public nonisolated enum SSHCommand {
  public static let sshExecutablePath = "/usr/bin/ssh"

  /// `%C` is ssh's hash of (local host, remote host, port, user): stable per
  /// connection and short, keeping the control socket well under the
  /// `sockaddr_un.sun_path` limit. ssh expands both `~` and `%C` itself.
  public static let defaultControlPath = "~/.ssh/supacode-%C"

  /// SSH connection-multiplexing options. `auto` opens a master if none exists
  /// and reuses it otherwise; `ControlPersist` keeps it warm briefly after the
  /// last client so a burst of git calls shares one connection.
  public static func controlOptions(controlPath: String = defaultControlPath) -> [String] {
    [
      "-o", "ControlMaster=auto",
      "-o", "ControlPath=\(controlPath)",
      "-o", "ControlPersist=10m",
    ]
  }

  /// Options for a non-interactive background probe (e.g. resolving a remote
  /// repository at launch). `BatchMode` so it fails fast instead of blocking on
  /// a password / host-key prompt; `ConnectTimeout` bounds the TCP+handshake;
  /// `ServerAlive*` aborts a connection that stalls mid-command (~10s). A live
  /// ControlMaster (an open terminal) bypasses auth, so the common case is fast.
  public static let backgroundProbeOptions: [String] = [
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=10",
    "-o", "ServerAliveInterval=5",
    "-o", "ServerAliveCountMax=2",
  ]

  /// POSIX single-quote a token so a parent shell passes it through literally.
  public static func shellQuote(_ value: String) -> String {
    "'" + value.replacing("'", with: "'\\''") + "'"
  }

  /// The command string the *remote* shell runs for a local
  /// `(executable, arguments, workingDirectory)` invocation. A working
  /// directory becomes `cd -- <dir> && exec ...` so the remote process starts
  /// in the worktree and replaces the shell (signals / exit status map
  /// straight through).
  public static func remoteCommand(
    executable: String,
    arguments: [String],
    workingDirectory: URL?
  ) -> String {
    let invocation = ([executable] + arguments).map(shellQuote).joined(separator: " ")
    guard let workingDirectory else {
      return invocation
    }
    let directory = shellQuote(workingDirectory.path(percentEncoded: false))
    return "cd -- \(directory) && exec \(invocation)"
  }

  /// Wrap a remote command so it runs under a **login** shell. ssh's default
  /// `$SHELL -c <cmd>` is non-interactive *and* non-login, so on macOS it only
  /// inherits `~/.zshenv`'s bare PATH (`/usr/bin:/bin:/usr/sbin:/sbin`), so
  /// Homebrew's `/opt/homebrew/bin` (where remote `zmx` / `git` / the `wt` shim
  /// live) is NOT on it and the remote command fails with `command not found`.
  /// A login shell reads `/etc/zprofile` (path_helper) + `~/.zprofile`
  /// (`brew shellenv`), restoring the full PATH. `$SHELL` is expanded by ssh's
  /// own outer shell; `exec` replaces it so signals / exit status pass through.
  public static func loginShellWrapped(_ remoteScript: String) -> String {
    "exec \"$SHELL\" -l -c " + shellQuote(remoteScript)
  }

  /// Login-shell-wrapped remote command that also forwards positional arguments
  /// (`$0`, `$1`, …) to the `-c` script, so an arbitrary payload (e.g. a user
  /// script) rides as `$1` instead of being concatenated into the script text.
  /// `exec "$SHELL" -l -c '<script>' <arg0> <arg1> …`.
  public static func loginShellWrapped(_ remoteScript: String, positionalArguments: [String]) -> String {
    var line = "exec \"$SHELL\" -l -c " + shellQuote(remoteScript)
    for argument in positionalArguments {
      line += " " + shellQuote(argument)
    }
    return line
  }

  /// Full local `ssh` argv for `Process` / `ShellClient`. The remote command is
  /// a single argument; ssh hands it to the remote login shell verbatim.
  public static func invocation(
    host: RemoteHost,
    executable: String,
    arguments: [String],
    workingDirectory: URL?,
    allocateTTY: Bool = false,
    controlPath: String = defaultControlPath,
    extraOptions: [String] = []
  ) -> (executableURL: URL, arguments: [String]) {
    var sshArguments = controlOptions(controlPath: controlPath)
    sshArguments += extraOptions
    if allocateTTY {
      sshArguments.append("-tt")
    }
    sshArguments += host.sshOptionArguments
    sshArguments.append(host.sshDestination)
    sshArguments.append(
      loginShellWrapped(
        remoteCommand(executable: executable, arguments: arguments, workingDirectory: workingDirectory)
      )
    )
    return (URL(fileURLWithPath: sshExecutablePath), sshArguments)
  }

  /// Full `ssh` line as a single string for a parent `/bin/sh -c` (Ghostty's
  /// surface command). The fixed option tokens are shell-safe and stay
  /// unquoted (so ssh still expands `~` / `%C` in `ControlPath`); the
  /// login-shell-wrapped remote command is quoted for the local shell.
  public static func commandLine(
    host: RemoteHost,
    remoteCommand: String,
    allocateTTY: Bool = true,
    controlPath: String = defaultControlPath
  ) -> String {
    var tokens = [sshExecutablePath]
    tokens += controlOptions(controlPath: controlPath)
    if allocateTTY {
      tokens.append("-tt")
    }
    tokens += host.sshOptionArguments
    tokens.append(host.sshDestination)
    tokens.append(shellQuote(loginShellWrapped(remoteCommand)))
    return tokens.joined(separator: " ")
  }

  /// `commandLine` variant that forwards positional arguments to the remote
  /// login-shell `-c` script, for callers that pass an arbitrary payload as
  /// `$1` (e.g. a blocking script's user command).
  public static func commandLine(
    host: RemoteHost,
    remoteScript: String,
    positionalArguments: [String],
    allocateTTY: Bool = true,
    controlPath: String = defaultControlPath
  ) -> String {
    var tokens = [sshExecutablePath]
    tokens += controlOptions(controlPath: controlPath)
    if allocateTTY {
      tokens.append("-tt")
    }
    tokens += host.sshOptionArguments
    tokens.append(host.sshDestination)
    tokens.append(shellQuote(loginShellWrapped(remoteScript, positionalArguments: positionalArguments)))
    return tokens.joined(separator: " ")
  }
}
