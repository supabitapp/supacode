import Foundation
import Testing

@testable import SupacodeSettingsShared

struct ShellClientLoginShellTests {
  @Test func supportedShellsRunAsThemselves() {
    for path in ["/bin/zsh", "/bin/bash", "/opt/homebrew/bin/fish"] {
      let result = ShellClient.loginShellInvocation(userShell: URL(fileURLWithPath: path), workingDirectory: nil)
      #expect(result.shell.path == path)
    }
  }

  @Test func fishKeepsItsOwnSnippet() {
    let result = ShellClient.loginShellInvocation(
      userShell: URL(fileURLWithPath: "/opt/homebrew/bin/fish"), workingDirectory: nil)
    #expect(result.shell.lastPathComponent == "fish")
    #expect(result.command.contains("exec $argv"))
    // fish scopes argv across source, so it must NOT get the zsh/bash capture (which isn't valid fish).
    #expect(!result.command.contains("__supacode_login_argv"))
  }

  @Test func bashSourcesBashrc() {
    let result = ShellClient.loginShellInvocation(userShell: URL(fileURLWithPath: "/bin/bash"), workingDirectory: nil)
    #expect(result.command.contains("~/.bashrc"))
    #expect(result.command.contains("exec \"${__supacode_login_argv[@]}\""))
  }

  /// Regression for #100: any shell we don't have a correct rc snippet for must
  /// fall back to /bin/zsh, which can parse it — instead of stranding the user
  /// with a bogus "not a git repository". Includes sh/dash/ksh, since sourcing
  /// `~/.zshrc` under them is a parse error (the original review catch).
  @Test func unsupportedShellsFallBackToZsh() {
    let shells = [
      "/run/current-system/sw/bin/nu", "/usr/bin/pwsh", "/opt/elvish", "/usr/bin/xonsh", "/bin/csh",
      "/bin/sh", "/usr/local/bin/dash", "/usr/bin/ksh",
    ]
    for path in shells {
      let result = ShellClient.loginShellInvocation(userShell: URL(fileURLWithPath: path), workingDirectory: nil)
      #expect(result.shell.path == "/bin/zsh")
      #expect(result.command.contains("exec \"${__supacode_login_argv[@]}\""))
    }
  }

  /// Regression for #441: the zsh/bash snippet must capture the positional parameters into the
  /// saved array BEFORE sourcing the rc file. Sourcing shares `$@` with the caller, so an rc that
  /// runs `set --` would otherwise wipe the command (`/usr/bin/which gh`) before `exec`.
  @Test func zshAndBashCaptureArgsBeforeSourcingRc() {
    for path in ["/bin/zsh", "/bin/bash"] {
      let command = ShellClient.loginShellInvocation(userShell: URL(fileURLWithPath: path), workingDirectory: nil)
        .command
      guard let captureRange = command.range(of: "__supacode_login_argv=(\"$@\")"),
        let sourceRange = command.range(of: "~/.")
      else {
        Issue.record("\(path) snippet missing capture or source: \(command)")
        continue
      }
      #expect(captureRange.lowerBound < sourceRange.lowerBound)
      #expect(command.contains("exec \"${__supacode_login_argv[@]}\""))
    }
  }

  /// Regression for #477: after capturing the positional parameters, the zsh/bash snippet must clear
  /// them (`set --`) BEFORE sourcing the rc file. The positionals otherwise leak into the rc, so a
  /// dual-mode script dispatching on `$1` (e.g. `fzf-git.sh`) sees the probe's `/usr/bin/which gh`,
  /// hits its own `exit`, and kills the probe shell before `gh` is ever resolved.
  @Test func zshAndBashClearPositionalsBeforeSourcingRc() {
    for path in ["/bin/zsh", "/bin/bash"] {
      let command = ShellClient.loginShellInvocation(userShell: URL(fileURLWithPath: path), workingDirectory: nil)
        .command
      guard let captureRange = command.range(of: "__supacode_login_argv=(\"$@\")"),
        let clearRange = command.range(of: "set --"),
        let sourceRange = command.range(of: "~/.")
      else {
        Issue.record("\(path) snippet missing capture, clear, or source: \(command)")
        continue
      }
      #expect(captureRange.lowerBound < clearRange.lowerBound)
      #expect(clearRange.lowerBound < sourceRange.lowerBound)
      #expect(command.contains("exec \"${__supacode_login_argv[@]}\""))
    }
  }

  /// Locks the exact strings so the shared-helper refactor can't drift them;
  /// the regressions above only assert with `.contains`.
  @Test func loginShellInvocationProducesExactStrings() {
    let zsh = ShellClient.loginShellInvocation(userShell: URL(fileURLWithPath: "/bin/zsh"), workingDirectory: nil)
    #expect(zsh.shell.path == "/bin/zsh")
    #expect(
      zsh.command
        == "__supacode_login_argv=(\"$@\"); set --; [ -f ~/.zshrc ] && . ~/.zshrc >/dev/null 2>&1; "
        + "exec \"${__supacode_login_argv[@]}\""
    )

    let bash = ShellClient.loginShellInvocation(userShell: URL(fileURLWithPath: "/bin/bash"), workingDirectory: nil)
    #expect(
      bash.command
        == "__supacode_login_argv=(\"$@\"); set --; [ -f ~/.bashrc ] && . ~/.bashrc >/dev/null 2>&1; "
        + "exec \"${__supacode_login_argv[@]}\""
    )

    let fish = ShellClient.loginShellInvocation(
      userShell: URL(fileURLWithPath: "/opt/homebrew/bin/fish"), workingDirectory: nil)
    #expect(
      fish.command
        == "test -f ~/.config/fish/config.fish; and source ~/.config/fish/config.fish >/dev/null 2>&1; exec $argv"
    )
  }

  /// #504: a literal-command probe sources rc (redirected to /dev/null) and execs
  /// the command last, so its exit status is what the caller sees and the
  /// watchdog's signal lands on the CLI, not an orphaned shell.
  @Test func loginShellCommandSourcesRcAndRunsCommand() {
    let zsh = ShellClient.loginShellCommandInvocation(
      "codex features enable hooks", userShell: URL(fileURLWithPath: "/bin/zsh"), workingDirectory: nil)
    #expect(zsh.shell.path == "/bin/zsh")
    #expect(zsh.command == "[ -f ~/.zshrc ] && . ~/.zshrc >/dev/null 2>&1; exec codex features enable hooks")

    let bash = ShellClient.loginShellCommandInvocation(
      "kiro-cli --version", userShell: URL(fileURLWithPath: "/bin/bash"), workingDirectory: nil)
    #expect(bash.command == "[ -f ~/.bashrc ] && . ~/.bashrc >/dev/null 2>&1; exec kiro-cli --version")
  }

  /// fish sources its own config and must NOT get the zsh/bash capture dance.
  @Test func loginShellCommandUsesFishConfig() {
    let fish = ShellClient.loginShellCommandInvocation(
      "codex features enable hooks", userShell: URL(fileURLWithPath: "/opt/homebrew/bin/fish"), workingDirectory: nil)
    #expect(fish.shell.lastPathComponent == "fish")
    #expect(
      fish.command
        == "test -f ~/.config/fish/config.fish; and source ~/.config/fish/config.fish >/dev/null 2>&1; "
        + "exec codex features enable hooks"
    )
    #expect(!fish.command.contains("__supacode_login_argv"))
  }

  /// Homebrew shells live outside /bin; selection keys off `lastPathComponent`,
  /// so they must run as themselves, not collapse to /bin/zsh.
  @Test func homebrewShellsRunAsThemselves() {
    for path in ["/opt/homebrew/bin/bash", "/opt/homebrew/bin/zsh", "/usr/local/bin/bash"] {
      let exec = ShellClient.loginShellInvocation(userShell: URL(fileURLWithPath: path), workingDirectory: nil)
      #expect(exec.shell.path == path)
      let literal = ShellClient.loginShellCommandInvocation(
        "x", userShell: URL(fileURLWithPath: path), workingDirectory: nil)
      #expect(literal.shell.path == path)
    }
  }

  /// Regression for #776: the working directory must be re-entered AFTER the rc
  /// is sourced, so an rc that changes directory cannot relocate the command.
  @Test func workingDirectoryGuardRunsAfterRcAndBeforeExec() {
    for path in ["/bin/zsh", "/bin/bash"] {
      let command = ShellClient.loginShellInvocation(
        userShell: URL(fileURLWithPath: path),
        workingDirectory: URL(fileURLWithPath: "/tmp/wt")
      ).command
      guard let sourceRange = command.range(of: "~/."),
        let guardRange = command.range(of: "builtin cd -- '/tmp/wt' >/dev/null"),
        let execRange = command.range(of: "exec \"${__supacode_login_argv[@]}\"")
      else {
        Issue.record("\(path) snippet missing source, guard, or exec: \(command)")
        continue
      }
      #expect(sourceRange.lowerBound < guardRange.lowerBound)
      #expect(guardRange.lowerBound < execRange.lowerBound)
    }
  }

  /// Locks the guarded strings too.
  @Test func workingDirectoryProducesExactStrings() {
    let directory = URL(fileURLWithPath: "/tmp/wt")
    let zsh = ShellClient.loginShellInvocation(
      userShell: URL(fileURLWithPath: "/bin/zsh"), workingDirectory: directory)
    #expect(
      zsh.command
        == "__supacode_login_argv=(\"$@\"); set --; [ -f ~/.zshrc ] && . ~/.zshrc >/dev/null 2>&1; "
        + "builtin cd -- '/tmp/wt' >/dev/null || exit 125; exec \"${__supacode_login_argv[@]}\""
    )

    let fish = ShellClient.loginShellInvocation(
      userShell: URL(fileURLWithPath: "/opt/homebrew/bin/fish"), workingDirectory: directory)
    #expect(
      fish.command
        == "test -f ~/.config/fish/config.fish; and source ~/.config/fish/config.fish >/dev/null 2>&1; "
        + "builtin cd -- '/tmp/wt' >/dev/null; or exit 125; exec $argv"
    )

    let literal = ShellClient.loginShellCommandInvocation(
      "gh pr list", userShell: URL(fileURLWithPath: "/bin/zsh"), workingDirectory: directory)
    #expect(
      literal.command
        == "[ -f ~/.zshrc ] && . ~/.zshrc >/dev/null 2>&1; "
        + "builtin cd -- '/tmp/wt' >/dev/null || exit 125; exec gh pr list"
    )
  }

  /// A nil working directory must leave the snippet byte-identical to the
  /// unguarded form, so the cwd-free probes (#504) are untouched. The exec form's
  /// exact strings are locked by `loginShellInvocationProducesExactStrings`.
  @Test func nilWorkingDirectoryEmitsNoGuard() {
    let literals = [
      "/bin/zsh": "[ -f ~/.zshrc ] && . ~/.zshrc >/dev/null 2>&1; exec x",
      "/bin/bash": "[ -f ~/.bashrc ] && . ~/.bashrc >/dev/null 2>&1; exec x",
      "/opt/homebrew/bin/fish":
        "test -f ~/.config/fish/config.fish; and source ~/.config/fish/config.fish >/dev/null 2>&1; exec x",
    ]
    for (path, expected) in literals {
      let shell = URL(fileURLWithPath: path)
      #expect(
        !ShellClient.loginShellInvocation(userShell: shell, workingDirectory: nil)
          .command.contains("builtin cd")
      )
      #expect(
        ShellClient.loginShellCommandInvocation("x", userShell: shell, workingDirectory: nil).command
          == expected
      )
    }
  }

  /// The guard must survive a path carrying the two bytes fish rewrites inside a
  /// single-quoted span. Asserted against a literal, not against the quoter the
  /// implementation itself calls.
  @Test func workingDirectoryQuotesHostilePaths() {
    let directory = URL(fileURLWithPath: "/tmp/it's a\\dir")
    for shellPath in ["/bin/zsh", "/bin/bash", "/opt/homebrew/bin/fish"] {
      let command = ShellClient.loginShellInvocation(
        userShell: URL(fileURLWithPath: shellPath), workingDirectory: directory
      ).command
      #expect(command.contains("builtin cd -- '/tmp/it'\"'\"'s a'\\\\'dir' >/dev/null"))
    }
  }

  /// The cwd handed to the spawn must be the same one baked into the snippet:
  /// threading nil into the builder while still passing it to the process would
  /// reintroduce #776 with every other test still green.
  @Test func processInvocationBakesTheWorkingDirectoryIntoArgv() {
    let directory = URL(fileURLWithPath: "/tmp/wt")
    let invocation = ShellClient.loginShellProcessInvocation(
      executableURL: URL(fileURLWithPath: "/usr/bin/env"),
      arguments: ["wt", "root"],
      currentDirectoryURL: directory,
      log: false
    )
    #expect(invocation.arguments.first == "-l")
    #expect(invocation.arguments[1] == "-c")
    #expect(invocation.arguments[2].contains("builtin cd -- '/tmp/wt' >/dev/null"))
    #expect(Array(invocation.arguments.dropFirst(3)) == ["--", "/usr/bin/env", "wt", "root"])

    let unguarded = ShellClient.loginShellProcessInvocation(
      executableURL: URL(fileURLWithPath: "/usr/bin/env"),
      arguments: [],
      currentDirectoryURL: nil,
      log: false
    )
    #expect(!unguarded.arguments[2].contains("builtin cd"))
  }

  /// Same #100 fallback as the exec form: an undrivable shell runs under /bin/zsh,
  /// and the command must survive the fallthrough.
  @Test func loginShellCommandFallsBackToZshForUnsupportedShells() {
    for path in ["/usr/bin/pwsh", "/bin/sh", "/usr/bin/ksh", "/run/current-system/sw/bin/nu"] {
      let result = ShellClient.loginShellCommandInvocation(
        "codex features enable hooks", userShell: URL(fileURLWithPath: path), workingDirectory: nil)
      #expect(result.shell.path == "/bin/zsh")
      #expect(result.command.contains("~/.zshrc"))
      #expect(result.command.hasSuffix("; exec codex features enable hooks"))
    }
  }
}

/// Runs the real snippet under real shells. `ShellClientLoginShellTests`' golden
/// strings cannot prove an rc's `cd` is actually defeated, which is all of #776.
struct ShellClientWorkingDirectoryProbeTests {
  /// The shells `drivableLoginShell` can emit; `sh` never reaches this snippet.
  nonisolated private static let shells = ["zsh", "bash", "fish"]

  /// Writes `body` where `rcSourceExpression` looks for it, given the isolated
  /// `HOME` / `XDG_CONFIG_HOME` that `LoginShellProbe.run` installs.
  private static func writeRc(_ body: String, shell: String, configRoot: URL) throws {
    let relativePath =
      switch shell {
      case "fish": ".config/fish/config.fish"
      case "bash": ".bashrc"
      default: ".zshrc"
      }
    let file = configRoot.appending(path: relativePath)
    try makeDirectories(file.deletingLastPathComponent())
    try Data(body.utf8).write(to: file)
  }

  private static func makeDirectories(_ urls: URL...) throws {
    for url in urls {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
  }

  /// The shells parsed the snippet and the command ran in `directory`.
  private static func expectRan(
    _ result: LoginShellProbe.Result,
    in directory: URL,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    #expect(result.shellDiagnostics.isEmpty, sourceLocation: sourceLocation)
    #expect(
      result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        == LoginShellProbe.physicalPath(of: directory),
      sourceLocation: sourceLocation
    )
  }

  /// An rc that changes directory. The same line parses in all three shells.
  private static func relocatingRc(to destination: URL) -> String {
    "cd '\(destination.path(percentEncoded: false))'"
  }

  /// `workingDirectory` is what the snippet re-enters. An outer nil
  /// `spawnDirectory` launches there too; `.some(x)` makes the two differ.
  private static func probe(
    shell: String,
    rcBody: String,
    workingDirectory: URL?,
    configRoot: URL,
    arguments: [String],
    spawnDirectory: URL?? = nil
  ) async throws -> LoginShellProbe.Result {
    try writeRc(rcBody, shell: shell, configRoot: configRoot)
    let command = ShellClient.loginShellInvocation(
      userShell: try LoginShellProbe.executable(shell),
      workingDirectory: workingDirectory
    ).command
    return try await LoginShellProbe.run(
      shell,
      command: command,
      configRoot: configRoot,
      workingDirectory: spawnDirectory ?? workingDirectory,
      trailingArguments: ["--"] + arguments
    )
  }

  /// #776 proper: Foundation set the cwd, the rc moves away, and the guard must
  /// put us back before the command runs.
  @Test(arguments: shells) func rcCannotRelocateTheCommand(shell: String) async throws {
    try await LoginShellProbe.withTemporaryDirectory("cwd-\(shell)") { root in
      let target = root.appending(path: "target")
      let elsewhere = root.appending(path: "elsewhere")
      try Self.makeDirectories(target, elsewhere)
      let result = try await Self.probe(
        shell: shell,
        rcBody: Self.relocatingRc(to: elsewhere),
        workingDirectory: target,
        configRoot: root.appending(path: "home"),
        arguments: ["/bin/pwd", "-P"]
      )
      Self.expectRan(result, in: target)
    }
  }

  /// The inverse, so `rcCannotRelocateTheCommand` proves the guard and not the
  /// harness: with no working directory the same rc still wins.
  @Test(arguments: shells) func rcRelocatesWhenNoWorkingDirectoryIsRequested(shell: String) async throws {
    try await LoginShellProbe.withTemporaryDirectory("nocwd-\(shell)") { root in
      let elsewhere = root.appending(path: "elsewhere")
      try Self.makeDirectories(elsewhere)
      let result = try await Self.probe(
        shell: shell,
        rcBody: Self.relocatingRc(to: elsewhere),
        workingDirectory: nil,
        configRoot: root.appending(path: "home"),
        arguments: ["/bin/pwd", "-P"]
      )
      Self.expectRan(result, in: elsewhere)
    }
  }

  /// Pins the harness leg `rcCannotRelocateTheCommand` rests on: without the
  /// spawn directory actually being applied, it would still pass.
  @Test(arguments: shells) func launchDirectoryIsAppliedWithoutAnyGuard(shell: String) async throws {
    try await LoginShellProbe.withTemporaryDirectory("launch-\(shell)") { root in
      let target = root.appending(path: "target")
      try Self.makeDirectories(target)
      let result = try await Self.probe(
        shell: shell,
        rcBody: "",
        workingDirectory: nil,
        configRoot: root.appending(path: "home"),
        arguments: ["/bin/pwd", "-P"],
        spawnDirectory: .some(target)
      )
      #expect(
        result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
          == LoginShellProbe.physicalPath(of: target)
      )
    }
  }

  /// A path carrying the bytes fish rewrites inside a single-quoted span has to
  /// survive as a real directory, not just as a golden string.
  @Test(arguments: shells) func hostileWorkingDirectoryPathSurvives(shell: String) async throws {
    try await LoginShellProbe.withTemporaryDirectory("hostile-\(shell)") { root in
      let target = root.appending(path: "it's a\\dir with space")
      let elsewhere = root.appending(path: "elsewhere")
      try Self.makeDirectories(target, elsewhere)
      let result = try await Self.probe(
        shell: shell,
        rcBody: Self.relocatingRc(to: elsewhere),
        workingDirectory: target,
        configRoot: root.appending(path: "home"),
        arguments: ["/bin/pwd", "-P"]
      )
      Self.expectRan(result, in: target)
    }
  }

  /// The guard shares one command string with the argv capture (#441, #477), so
  /// an argument needing quoting must still arrive intact alongside it.
  @Test(arguments: shells) func guardDoesNotDisturbArguments(shell: String) async throws {
    try await LoginShellProbe.withTemporaryDirectory("argv-\(shell)") { root in
      let target = root.appending(path: "target")
      try Self.makeDirectories(target)
      let result = try await Self.probe(
        shell: shell,
        rcBody: Self.relocatingRc(to: root),
        workingDirectory: target,
        configRoot: root.appending(path: "home"),
        arguments: ["/bin/echo", "a b", "it's", "$HOME"]
      )
      #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "a b it's $HOME")
    }
  }

  /// Callers parse this stdout, so an rc `cd` hook must not print into it (#776).
  @Test(arguments: shells) func guardKeepsRcHookOutputOffStdout(shell: String) async throws {
    let noisyRc =
      switch shell {
      case "fish": "function cd; builtin cd $argv; echo NOISE; end"
      case "bash": "cd() { builtin cd \"$@\"; echo NOISE; }"
      default: "chpwd() { echo NOISE }"
      }
    try await LoginShellProbe.withTemporaryDirectory("noise-\(shell)") { root in
      let target = root.appending(path: "target")
      try Self.makeDirectories(target)
      let result = try await Self.probe(
        shell: shell,
        rcBody: noisyRc,
        workingDirectory: target,
        configRoot: root.appending(path: "home"),
        arguments: ["/bin/pwd", "-P"]
      )
      #expect(!result.stdout.contains("NOISE"))
      #expect(
        result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
          == LoginShellProbe.physicalPath(of: target)
      )
    }
  }

  /// Spawned from the temp root rather than the missing directory: Foundation
  /// throws at launch for a cwd that does not exist, so in production this guard
  /// only ever faces a directory that vanished after the process started.
  @Test(arguments: shells) func unenterableWorkingDirectoryFailsLoudly(shell: String) async throws {
    try await LoginShellProbe.withTemporaryDirectory("missing-\(shell)") { root in
      let missing = root.appending(path: "does-not-exist")
      let result = try await Self.probe(
        shell: shell,
        rcBody: "",
        workingDirectory: missing,
        configRoot: root.appending(path: "home"),
        arguments: ["/bin/echo", "RAN"],
        spawnDirectory: .some(root)
      )
      #expect(result.status == Int32(ShellClient.workingDirectoryExitCode))
      #expect(result.stderr.contains(missing.lastPathComponent))
      #expect(!result.stdout.contains("RAN"))
    }
  }
}
