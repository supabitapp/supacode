import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

struct RemoteHostTests {
  @Test func bareAliasHasNoUserOrPortOptions() {
    let host = RemoteHost(alias: "devbox")
    #expect(host.sshDestination == "devbox")
    #expect(host.sshOptionArguments.isEmpty)
  }

  @Test func usernameAndPortProjectIntoDestinationAndOptions() {
    let host = RemoteHost(alias: "box", username: "alice", port: 2222)
    #expect(host.sshDestination == "alice@box")
    #expect(host.sshOptionArguments == ["-p", "2222"])
  }

  @Test func emptyUsernameFallsBackToBareAlias() {
    let host = RemoteHost(alias: "box", username: "")
    #expect(host.sshDestination == "box")
  }
}

struct SSHCommandTests {
  @Test func shellQuoteWrapsAndEscapesSingleQuotes() {
    #expect(SSHCommand.shellQuote("echo hi") == "'echo hi'")
    #expect(SSHCommand.shellQuote("echo 'hi'") == "'echo '\\''hi'\\'''")
  }

  @Test func remoteCommandWithoutWorkingDirectoryQuotesEachToken() {
    let command = SSHCommand.remoteCommand(
      executable: "git",
      arguments: ["status", "--short"],
      workingDirectory: nil
    )
    #expect(command == "'git' 'status' '--short'")
  }

  @Test func remoteCommandWithWorkingDirectoryPrependsCdAndExec() {
    let command = SSHCommand.remoteCommand(
      executable: "/usr/bin/env",
      arguments: ["git", "status"],
      workingDirectory: URL(fileURLWithPath: "/tmp/repo")
    )
    #expect(command == "cd -- '/tmp/repo' && exec '/usr/bin/env' 'git' 'status'")
  }

  @Test func loginShellWrappedExecsLoginShellWithQuotedScript() {
    #expect(SSHCommand.loginShellWrapped("zmx attach s") == "exec \"$SHELL\" -l -c 'zmx attach s'")
    #expect(SSHCommand.loginShellWrapped("echo 'hi'") == "exec \"$SHELL\" -l -c 'echo '\\''hi'\\'''")
  }

  @Test func loginShellWrappedQuotesEachPositionalArgumentSeparately() {
    // A payload containing a single quote and a space must ride as a quoted positional arg,
    // never interpolated into the script text.
    #expect(
      SSHCommand.loginShellWrapped("$0 \"$@\"", positionalArguments: ["claude", "it's a test"])
        == "exec \"$SHELL\" -l -c '$0 \"$@\"' 'claude' 'it'\\''s a test'"
    )
  }

  @Test func invocationWrapsRemoteCommandInLoginShellAfterMultiplexingOptions() {
    let result = SSHCommand.invocation(
      host: RemoteHost(alias: "devbox"),
      executable: "/usr/bin/env",
      arguments: ["git", "-C", "/tmp/repo", "status"],
      workingDirectory: URL(fileURLWithPath: "/tmp/repo")
    )
    #expect(result.executableURL == URL(fileURLWithPath: "/usr/bin/ssh"))
    let expectedScript = SSHCommand.remoteCommand(
      executable: "/usr/bin/env",
      arguments: ["git", "-C", "/tmp/repo", "status"],
      workingDirectory: URL(fileURLWithPath: "/tmp/repo")
    )
    #expect(
      result.arguments == [
        "-o", "ControlMaster=auto",
        "-o", "ControlPath=~/.ssh/supacode-%C",
        "-o", "ControlPersist=10m",
        "devbox",
        SSHCommand.loginShellWrapped(expectedScript),
      ]
    )
    // The wrapped arg actually carries the git invocation under a login shell.
    #expect(result.arguments.last?.hasPrefix("exec \"$SHELL\" -l -c ") == true)
    #expect(result.arguments.last?.contains("git") == true)
  }

  @Test func invocationAllocatesTTYAndForwardsPortWhenRequested() {
    let result = SSHCommand.invocation(
      host: RemoteHost(alias: "box", username: "alice", port: 2222),
      executable: "zmx",
      arguments: ["ls"],
      workingDirectory: nil,
      allocateTTY: true
    )
    #expect(
      result.arguments == [
        "-o", "ControlMaster=auto",
        "-o", "ControlPath=~/.ssh/supacode-%C",
        "-o", "ControlPersist=10m",
        "-tt",
        "-p", "2222",
        "alice@box",
        SSHCommand.loginShellWrapped("'zmx' 'ls'"),
      ]
    )
  }

  @Test func commandLineWrapsRemoteCommandInLoginShellQuotedForLocalShell() {
    let line = SSHCommand.commandLine(
      host: RemoteHost(alias: "devbox"),
      remoteCommand: "zmx attach supa-x"
    )
    let expectedTail = SSHCommand.shellQuote(SSHCommand.loginShellWrapped("zmx attach supa-x"))
    #expect(
      line
        == "/usr/bin/ssh -o ControlMaster=auto -o ControlPath=~/.ssh/supacode-%C -o ControlPersist=10m -tt devbox "
        + expectedTail
    )
  }

  @Test func commandLineForwardsPositionalArgumentsQuotedForLocalShell() {
    // A payload containing a single quote and a space rides as a positional arg, double-quoted
    // for the local shell on top of the inner per-arg quoting.
    let line = SSHCommand.commandLine(
      host: RemoteHost(alias: "devbox"),
      remoteScript: "$0 \"$@\"",
      positionalArguments: ["claude", "it's a test"]
    )
    let expectedTail = SSHCommand.shellQuote(
      SSHCommand.loginShellWrapped("$0 \"$@\"", positionalArguments: ["claude", "it's a test"])
    )
    #expect(
      line
        == "/usr/bin/ssh -o ControlMaster=auto -o ControlPath=~/.ssh/supacode-%C -o ControlPersist=10m -tt devbox "
        + expectedTail
    )
  }
}

struct ZmxAttachRemoteTests {
  private let surfaceID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AB")!
  // Surface-id export plus the beta banner, the fixed prefix of every remote command.
  private var surfacePrelude: String {
    "export SUPACODE_SURFACE_ID='\(surfaceID.uuidString)'; " + ZmxAttach.betaBanner
  }
  private let localZmx = "/Applications/Supacode.app/Contents/MacOS/zmx"

  @Test func remoteShellCommandWithoutUserCommandExportsSurfaceThenExecsLoginShell() {
    #expect(
      ZmxAttach.remoteShellCommand(userCommand: nil, surfaceID: surfaceID)
        == surfacePrelude + "exec \"$SHELL\" -l"
    )
  }

  @Test func remoteShellCommandIgnoresWhitespaceUserCommand() {
    #expect(
      ZmxAttach.remoteShellCommand(userCommand: "  \n", surfaceID: surfaceID)
        == surfacePrelude + "exec \"$SHELL\" -l"
    )
  }

  @Test func remoteShellCommandRunsUserCommandDirectly() {
    // No zmx on the remote: the command runs straight under the remote login shell.
    #expect(
      ZmxAttach.remoteShellCommand(userCommand: "claude --resume", surfaceID: surfaceID)
        == surfacePrelude + "claude --resume"
    )
  }

  @Test func remoteShellCommandPrintsBetaBannerAtConnection() {
    let command = ZmxAttach.remoteShellCommand(userCommand: nil, surfaceID: surfaceID)
    #expect(command.contains("beta"))
    // Banner precedes the shell so it lands at the top on connect.
    let bannerIndex = command.range(of: "beta")?.lowerBound
    let shellIndex = command.range(of: "exec ")?.lowerBound
    #expect(bannerIndex != nil && shellIndex != nil && bannerIndex! < shellIndex!)
  }

  @Test func buildRemoteCommandWrapsSSHInLocalZmxWithoutReverseForward() {
    let host = RemoteHost(alias: "devbox")
    let sshLine = SSHCommand.commandLine(
      host: host,
      remoteCommand: ZmxAttach.remoteShellCommand(userCommand: nil, surfaceID: surfaceID)
    )
    let command = ZmxAttach.buildRemoteCommand(
      host: host,
      localZmxExecutablePath: localZmx,
      sessionID: "supa-deadbeef",
      userCommand: nil,
      surfaceID: surfaceID
    )
    // Local zmx owns the session; its child process is the whole ssh line.
    #expect(
      command
        == ZmxAttach.buildCommand(executablePath: localZmx, sessionID: "supa-deadbeef", userCommand: sshLine)
    )
    #expect(command.contains("attach supa-deadbeef"))
    #expect(command.contains(localZmx))
    #expect(command.contains("SUPACODE_SURFACE_ID="))
    // The remote never runs zmx.
    #expect(!command.contains("zmx attach"))
    // Presence rides the OSC stream now, with no reverse socket / remote socket path.
    #expect(!command.contains("-R "))
    #expect(!command.contains("SUPACODE_SOCKET_PATH"))
  }

  @Test func buildRemoteCommandFallsBackToBareSSHWhenLocalZmxUnavailable() {
    let host = RemoteHost(alias: "devbox")
    let command = ZmxAttach.buildRemoteCommand(
      host: host,
      localZmxExecutablePath: nil,
      sessionID: "supa-x",
      userCommand: nil,
      surfaceID: surfaceID
    )
    #expect(
      command
        == SSHCommand.commandLine(
          host: host,
          remoteCommand: ZmxAttach.remoteShellCommand(userCommand: nil, surfaceID: surfaceID)
        )
    )
    #expect(!command.contains("attach "))
  }

  @Test func buildRemoteCommandForwardsUsernameAndPort() {
    let host = RemoteHost(alias: "box", username: "alice", port: 2222)
    let command = ZmxAttach.buildRemoteCommand(
      host: host,
      localZmxExecutablePath: localZmx,
      sessionID: "supa-x",
      userCommand: nil,
      surfaceID: surfaceID
    )
    #expect(command.contains("-p 2222 alice@box "))
  }
}
