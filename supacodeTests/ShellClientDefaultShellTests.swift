import Testing

@testable import supacode

struct ShellClientDefaultShellTests {
  @Test func loginShellPathUsesSupportedEnvironmentShell() {
    let selected = loginShellPath(
      environmentShell: "/bin/zsh",
      passwdShell: "/bin/bash"
    )
    #expect(selected == "/bin/zsh")
  }

  @Test func loginShellPathFallsBackWhenEnvironmentShellUnsupported() {
    let selected = loginShellPath(
      environmentShell: "/run/current-system/sw/bin/nu",
      passwdShell: "/bin/zsh"
    )
    #expect(selected == "/bin/zsh")
  }

  @Test func loginShellPathFallsBackToZshWhenNoSupportedShellExists() {
    let selected = loginShellPath(
      environmentShell: "/run/current-system/sw/bin/nu",
      passwdShell: "/run/current-system/sw/bin/nu"
    )
    #expect(selected == "/bin/zsh")
  }
}
