import Foundation
import Testing

@testable import SupacodeSettingsShared

struct ShellClientLoginShellTests {
  @Test func supportedShellsRunAsThemselves() {
    for path in ["/bin/zsh", "/bin/bash", "/opt/homebrew/bin/fish"] {
      let result = ShellClient.loginShellInvocation(userShell: URL(fileURLWithPath: path))
      #expect(result.shell.path == path)
    }
  }

  @Test func fishKeepsItsOwnSnippet() {
    let result = ShellClient.loginShellInvocation(userShell: URL(fileURLWithPath: "/opt/homebrew/bin/fish"))
    #expect(result.shell.lastPathComponent == "fish")
    #expect(result.command.contains("exec $argv"))
    // fish scopes argv across source, so it must NOT get the zsh/bash capture (which isn't valid fish).
    #expect(!result.command.contains("__supacode_login_argv"))
  }

  @Test func bashSourcesBashrc() {
    let result = ShellClient.loginShellInvocation(userShell: URL(fileURLWithPath: "/bin/bash"))
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
      let result = ShellClient.loginShellInvocation(userShell: URL(fileURLWithPath: path))
      #expect(result.shell.path == "/bin/zsh")
      #expect(result.command.contains("exec \"${__supacode_login_argv[@]}\""))
    }
  }

  /// Regression for #441: the zsh/bash snippet must capture the positional parameters into the
  /// saved array BEFORE sourcing the rc file. Sourcing shares `$@` with the caller, so an rc that
  /// runs `set --` would otherwise wipe the command (`/usr/bin/which gh`) before `exec`.
  @Test func zshAndBashCaptureArgsBeforeSourcingRc() {
    for path in ["/bin/zsh", "/bin/bash"] {
      let command = ShellClient.loginShellInvocation(userShell: URL(fileURLWithPath: path)).command
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
      let command = ShellClient.loginShellInvocation(userShell: URL(fileURLWithPath: path)).command
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
    let zsh = ShellClient.loginShellInvocation(userShell: URL(fileURLWithPath: "/bin/zsh"))
    #expect(zsh.shell.path == "/bin/zsh")
    #expect(
      zsh.command
        == "__supacode_login_argv=(\"$@\"); set --; [ -f ~/.zshrc ] && . ~/.zshrc >/dev/null 2>&1; "
        + "exec \"${__supacode_login_argv[@]}\""
    )

    let bash = ShellClient.loginShellInvocation(userShell: URL(fileURLWithPath: "/bin/bash"))
    #expect(
      bash.command
        == "__supacode_login_argv=(\"$@\"); set --; [ -f ~/.bashrc ] && . ~/.bashrc >/dev/null 2>&1; "
        + "exec \"${__supacode_login_argv[@]}\""
    )

    let fish = ShellClient.loginShellInvocation(userShell: URL(fileURLWithPath: "/opt/homebrew/bin/fish"))
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
      "codex features enable hooks", userShell: URL(fileURLWithPath: "/bin/zsh"))
    #expect(zsh.shell.path == "/bin/zsh")
    #expect(zsh.command == "[ -f ~/.zshrc ] && . ~/.zshrc >/dev/null 2>&1; exec codex features enable hooks")

    let bash = ShellClient.loginShellCommandInvocation(
      "kiro-cli --version", userShell: URL(fileURLWithPath: "/bin/bash"))
    #expect(bash.command == "[ -f ~/.bashrc ] && . ~/.bashrc >/dev/null 2>&1; exec kiro-cli --version")
  }

  /// fish sources its own config and must NOT get the zsh/bash capture dance.
  @Test func loginShellCommandUsesFishConfig() {
    let fish = ShellClient.loginShellCommandInvocation(
      "codex features enable hooks", userShell: URL(fileURLWithPath: "/opt/homebrew/bin/fish"))
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
      let exec = ShellClient.loginShellInvocation(userShell: URL(fileURLWithPath: path))
      #expect(exec.shell.path == path)
      let literal = ShellClient.loginShellCommandInvocation("x", userShell: URL(fileURLWithPath: path))
      #expect(literal.shell.path == path)
    }
  }

  /// Same #100 fallback as the exec form: an undrivable shell runs under /bin/zsh,
  /// and the command must survive the fallthrough.
  @Test func loginShellCommandFallsBackToZshForUnsupportedShells() {
    for path in ["/usr/bin/pwsh", "/bin/sh", "/usr/bin/ksh", "/run/current-system/sw/bin/nu"] {
      let result = ShellClient.loginShellCommandInvocation(
        "codex features enable hooks", userShell: URL(fileURLWithPath: path))
      #expect(result.shell.path == "/bin/zsh")
      #expect(result.command.contains("~/.zshrc"))
      #expect(result.command.hasSuffix("; exec codex features enable hooks"))
    }
  }
}
