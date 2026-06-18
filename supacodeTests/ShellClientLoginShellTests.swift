import Foundation
import Testing

@testable import SupacodeSettingsShared

struct ShellClientLoginShellTests {
  @Test func posixShellsAreDrivenDirectly() {
    for path in ["/bin/zsh", "/bin/bash", "/bin/sh", "/usr/local/bin/dash", "/usr/bin/ksh"] {
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

  /// Regression for #100: a non-POSIX login shell (Nushell) can't run our
  /// `-l -c <POSIX snippet>`, so the invocation must fall back to /bin/zsh
  /// instead of stranding the user with a bogus "not a git repository".
  @Test func nonPosixShellsFallBackToZsh() {
    for path in ["/run/current-system/sw/bin/nu", "/usr/bin/pwsh", "/opt/elvish", "/usr/bin/xonsh", "/bin/csh"] {
      let result = ShellClient.loginShellInvocation(userShell: URL(fileURLWithPath: path))
      #expect(result.shell.path == "/bin/zsh")
      #expect(result.command.contains("exec \"$@\""))
    }
  }
}
