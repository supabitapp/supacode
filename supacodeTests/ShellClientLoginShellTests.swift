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
  }

  @Test func bashSourcesBashrc() {
    let result = ShellClient.loginShellInvocation(userShell: URL(fileURLWithPath: "/bin/bash"))
    #expect(result.command.contains("~/.bashrc"))
    #expect(result.command.contains("exec \"$@\""))
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
      #expect(result.command.contains("exec \"$@\""))
    }
  }
}
