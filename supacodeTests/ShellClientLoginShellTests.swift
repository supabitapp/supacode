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
}
