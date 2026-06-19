import Foundation
import SupacodeSettingsShared

/// Pure helpers for the blocking-script wrapper: temp-dir layout, shell-script
/// generation, and shell single-quote escaping.
enum BlockingScriptRunner {
  struct LaunchArtifacts {
    let directoryURL: URL
    let runnerURL: URL
    let scriptURL: URL
    let shellPathURL: URL
    let commandInput: String
  }

  static func makeCommandInput(script: String) -> String? {
    let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return trimmed + "\n"
  }

  static func makeLaunch(
    script: String,
    shellPath: String,
    baseDirectoryURL: URL = FileManager.default.temporaryDirectory
  ) throws -> LaunchArtifacts? {
    let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let fileManager = FileManager.default
    let directoryURL = baseDirectoryURL.appending(
      path: "supacode-blocking-script-\(UUID().uuidString.lowercased())",
      directoryHint: .isDirectory
    )
    let runnerURL = directoryURL.appending(path: "run", directoryHint: .notDirectory)
    let scriptURL = directoryURL.appending(path: "script", directoryHint: .notDirectory)
    let shellPathURL = directoryURL.appending(path: "shell-path", directoryHint: .notDirectory)

    do {
      try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
      // Restrict to owner-only: the user's script may contain secrets.
      try fileManager.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: directoryURL.path(percentEncoded: false)
      )
      try Data((trimmed + "\n").utf8).write(to: scriptURL, options: [.atomic])
      try fileManager.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: scriptURL.path(percentEncoded: false)
      )
      try Data((shellPath + "\n").utf8).write(to: shellPathURL, options: [.atomic])
      try fileManager.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: shellPathURL.path(percentEncoded: false)
      )
      try Data(
        runnerScript(scriptURL: scriptURL, shellPathURL: shellPathURL).utf8
      ).write(to: runnerURL, options: [.atomic])
      try fileManager.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: runnerURL.path(percentEncoded: false)
      )
    } catch {
      try? fileManager.removeItem(at: directoryURL)
      throw error
    }

    return LaunchArtifacts(
      directoryURL: directoryURL,
      runnerURL: runnerURL,
      scriptURL: scriptURL,
      shellPathURL: shellPathURL,
      commandInput: shellSingleQuoted(runnerURL.path(percentEncoded: false)) + "\n"
    )
  }

  static func runnerScript(scriptURL: URL, shellPathURL: URL) -> String {
    let quotedShellPath = shellSingleQuoted(shellPathURL.path(percentEncoded: false))
    let quotedScriptPath = shellSingleQuoted(scriptURL.path(percentEncoded: false))

    // Signal traps route through `exit 127` so the EXIT trap fires exactly once
    // with the right code; `trap -` clears it before the natural-completion emit.
    return """
      #!/bin/sh
      set -u
      SUPACODE_EXIT=127
      trap 'printf "\\033]133;D;%d\\007" "$SUPACODE_EXIT"' EXIT
      trap 'exit 127' INT TERM HUP QUIT PIPE
      printf '\\033]133;C\\007'
      SUPACODE_SHELL_PATH_FILE=\(quotedShellPath)
      if [ ! -r "$SUPACODE_SHELL_PATH_FILE" ]; then
        printf '\\r\\nerror: missing shell-path file\\r\\n' >&2
        if [ -t 0 ]; then
          trap - EXIT
          printf '\\033]133;D;%d\\007' "$SUPACODE_EXIT"
          printf '\\r\\n\\033[2m── Script aborted (missing shell-path). Tab is read-only. ──\\033[0m\\r\\n'
          exec tail -f /dev/null
        fi
        exit 127
      fi
      IFS= read -r SUPACODE_SHELL_PATH < "$SUPACODE_SHELL_PATH_FILE" || exit 127
      "$SUPACODE_SHELL_PATH" -l \(quotedScriptPath)
      SUPACODE_EXIT=$?
      trap - EXIT
      printf '\\033]133;D;%d\\007' "$SUPACODE_EXIT"
      if [ -t 0 ]; then
        printf '\\r\\n\\033[2m── Script finished (exit code: %d). Tab is read-only. ──\\033[0m\\r\\n' "$SUPACODE_EXIT"
        exec tail -f /dev/null
      fi
      exit "$SUPACODE_EXIT"
      """
  }

  static func shellSingleQuoted(_ value: String) -> String {
    "'\(value.replacing("'", with: "'\"'\"'"))'"
  }

  /// Full local surface command for a blocking script on a *remote* worktree:
  /// an `ssh -tt <host> …` line (no local zmx wrapping, so it dies with the
  /// app like a local blocking script) that runs the same OSC 133 framing on
  /// the host. The user script rides as `$1`, so arbitrary script text needs no
  /// remote temp file. Returns nil for an empty script.
  static func remoteCommand(host: RemoteHost, script: String, remoteWorktreePath: String) -> String? {
    let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return SSHCommand.commandLine(
      host: host,
      remoteScript: remoteRunnerScript(remoteWorktreePath: remoteWorktreePath),
      positionalArguments: ["supacode-blocking", trimmed]
    )
  }

  /// The script the *remote* login shell runs for a blocking script. Mirrors
  /// `runnerScript` (OSC 133 begin/end framing, read-only `tail -f /dev/null`
  /// on completion) but runs on the host: it `cd`s into the remote worktree,
  /// prints the remote beta banner, and runs the user script (`$1`) as a login
  /// shell child so a `exit` in the script can't skip the completion emit.
  static func remoteRunnerScript(remoteWorktreePath: String) -> String {
    let trimmedPath = remoteWorktreePath.trimmingCharacters(in: .whitespacesAndNewlines)
    // Abort on a failed `cd` so a blocking script (user / delete / archive)
    // never runs in the login shell's `$HOME` when the worktree directory was
    // removed or renamed on the host after it was loaded.
    let cdLine =
      (trimmedPath.isEmpty || trimmedPath == "/")
      ? ""
      : "if ! cd -- \(shellSingleQuoted(trimmedPath)) 2>/dev/null; then "
        + "printf '\\r\\n\\033[2m── Could not enter the worktree directory; script not run. ──\\033[0m\\r\\n'; "
        + "SUPACODE_EXIT=1; exit 1; fi\n"
    return """
      set -u
      SUPACODE_EXIT=127
      trap 'printf "\\033]133;D;%d\\007" "$SUPACODE_EXIT"' EXIT
      trap 'exit 127' INT TERM HUP QUIT PIPE
      printf '\\033]133;C\\007'
      \(ZmxAttach.betaBanner)
      \(cdLine)"$SHELL" -l -c "$1"
      SUPACODE_EXIT=$?
      trap - EXIT
      printf '\\033]133;D;%d\\007' "$SUPACODE_EXIT"
      if [ -t 0 ]; then
        printf '\\r\\n\\033[2m── Script finished (exit code: %d). Tab is read-only. ──\\033[0m\\r\\n' "$SUPACODE_EXIT"
        exec tail -f /dev/null
      fi
      exit "$SUPACODE_EXIT"
      """
  }
}
