import Foundation
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct ZmxSessionIDTests {
  @Test func makeProducesStablePrefixAndLowercaseUUID() {
    let surface = UUID(uuidString: "DEADBEEF-DEAD-BEEF-DEAD-BEEFDEADBEEF")!
    #expect(ZmxSessionID.make(surfaceID: surface) == "supa-deadbeef-dead-beef-dead-beefdeadbeef")
  }

  @Test func makeFitsWithinDefaultSocketBudget() {
    // 41 chars leaves headroom under zmx's ~46-char default-dir budget.
    for _ in 0..<32 {
      let name = ZmxSessionID.make(surfaceID: UUID())
      #expect(name.count <= 46, "Session name '\(name)' is too long: \(name.count) chars")
    }
  }

  @Test func makeIsDeterministic() {
    let surface = UUID()
    let first = ZmxSessionID.make(surfaceID: surface)
    let second = ZmxSessionID.make(surfaceID: surface)
    #expect(first == second)
  }

  @Test func makeIsUniquePerSurface() {
    let first = ZmxSessionID.make(surfaceID: UUID())
    let second = ZmxSessionID.make(surfaceID: UUID())
    #expect(first != second)
  }
}

@MainActor
struct ZmxAttachTests {
  @Test func buildCommandWithoutUserCommandUsesAttachOnly() {
    let cmd = ZmxAttach.buildCommand(
      executablePath: "/path/to/zmx",
      sessionID: "supa-abc",
      userCommand: nil
    )
    #expect(cmd == "'/path/to/zmx' attach supa-abc")
  }

  @Test func buildCommandIgnoresEmptyOrWhitespaceUserCommand() {
    let blank = ZmxAttach.buildCommand(
      executablePath: "/zmx",
      sessionID: "s",
      userCommand: "   \n"
    )
    #expect(blank == "'/zmx' attach s")
  }

  @Test func buildCommandWrapsUserCommandViaShellC() {
    let cmd = ZmxAttach.buildCommand(
      executablePath: "/zmx",
      sessionID: "s",
      userCommand: "echo hello && date"
    )
    #expect(cmd == "'/zmx' attach s /bin/sh -c 'echo hello && date'")
  }

  @Test func buildCommandQuotesPathsContainingSpaces() {
    let cmd = ZmxAttach.buildCommand(
      executablePath: "/Applications/Supacode.app/Contents/Resources/zmx/zmx",
      sessionID: "s",
      userCommand: nil
    )
    #expect(cmd.hasPrefix("'/Applications/Supacode.app/Contents/Resources/zmx/zmx'"))
  }

  @Test func shellQuoteEscapesSingleQuotesInUserCommand() {
    let cmd = ZmxAttach.buildCommand(
      executablePath: "/zmx",
      sessionID: "s",
      userCommand: "echo 'hi'"
    )
    #expect(cmd == "'/zmx' attach s /bin/sh -c 'echo '\\''hi'\\'''")
  }

  /// The interactive wrapper argv is exactly `[exe, "attach", sessionID]`, each a
  /// separate element (no shell string), so Ghostty execs it directly.
  @Test func buildWrapperArgvIsAttachWithSession() {
    let argv = ZmxAttach.buildWrapperArgv(executablePath: "/path/to/zmx", sessionID: "supa-abc")
    #expect(argv == ["/path/to/zmx", "attach", "supa-abc"])
  }

  /// A path with spaces stays a single argv element (no quoting / re-splitting),
  /// since Ghostty receives a tokenized `direct:` command.
  @Test func buildWrapperArgvKeepsSpacedPathAsOneElement() {
    let argv = ZmxAttach.buildWrapperArgv(
      executablePath: "/Applications/Supacode Dev.app/Contents/Resources/zmx/zmx",
      sessionID: "supa-1"
    )
    #expect(argv.count == 3)
    #expect(argv[0] == "/Applications/Supacode Dev.app/Contents/Resources/zmx/zmx")
    #expect(argv[1] == "attach")
    #expect(argv[2] == "supa-1")
  }
}

@MainActor
struct ZmxSocketBudgetTests {
  @Test func probeAcceptsDefaultMacOSSocketDir() {
    // Default `/tmp/zmx-501` is ~13 chars; `supa-<UUID>` is 41 chars; total 55B,
    // well under 102B budget. Probe must return nil.
    #expect(ZmxSocketBudget.probe() == nil)
  }

  @Test func socketDirHonorsZmxDirEnv() {
    #expect(ZmxSocketBudget.socketDir(env: ["ZMX_DIR": "/custom/path"]) == "/custom/path")
  }

  @Test func socketDirFallsBackThroughXdgAndTmp() {
    let xdg = ZmxSocketBudget.socketDir(env: ["XDG_RUNTIME_DIR": "/xdg"])
    #expect(xdg == "/xdg/zmx")
    let tmp = ZmxSocketBudget.socketDir(env: ["TMPDIR": "/tmp/foo/"])
    let uid = getuid()
    #expect(tmp == "/tmp/foo/zmx-\(uid)")
  }

  @Test func socketDirInsertsSeparatorWhenTmpdirLacksTrailingSlash() {
    // Regression guard: zmx's own resolver trims trailing slashes and inserts
    // one, so `TMPDIR=/tmp` (no slash) must produce `/tmp/zmx-<uid>` here too.
    // Without the trim, kill and the wrapped shell would resolve different
    // socket dirs and sessions would leak silently.
    let uid = getuid()
    #expect(ZmxSocketBudget.socketDir(env: ["TMPDIR": "/tmp"]) == "/tmp/zmx-\(uid)")
    #expect(ZmxSocketBudget.socketDir(env: ["TMPDIR": "/var/folders/abc"]) == "/var/folders/abc/zmx-\(uid)")
    // Multiple trailing slashes also collapse.
    #expect(ZmxSocketBudget.socketDir(env: ["TMPDIR": "/tmp//"]) == "/tmp/zmx-\(uid)")
  }

  @Test func socketDirHandlesXdgWithoutTrailingSlash() {
    // Symmetric regression for the XDG branch.
    #expect(ZmxSocketBudget.socketDir(env: ["XDG_RUNTIME_DIR": "/run/user/501/"]) == "/run/user/501/zmx")
    #expect(ZmxSocketBudget.socketDir(env: ["XDG_RUNTIME_DIR": "/run/user/501"]) == "/run/user/501/zmx")
  }

  @Test func probeFlagsBudgetExceededForOverLongCustomDir() {
    let longDir = String(repeating: "a", count: 80)
    let reason = ZmxSocketBudget.probe(env: ["ZMX_DIR": longDir])
    #expect(reason?.contains("exceeds budget") == true)
  }

  @Test func probeAcceptsShortCustomDir() {
    #expect(ZmxSocketBudget.probe(env: ["ZMX_DIR": "/tmp"]) == nil)
  }
}

@MainActor
struct ZmxResolveLaunchTests {
  /// Interactive surface (nil command): nil command + `[exe, attach, id]` wrapper,
  /// so Ghostty resolves + integrates the real shell and zmx wraps the result.
  @Test func interactiveSurfaceGetsWrapperAndNilCommand() {
    let resolved = ZmxAttach.resolveLaunch(executablePath: "/zmx", sessionID: "supa-abc", command: nil)
    #expect(resolved.command == nil)
    #expect(resolved.commandWrapper == ["/zmx", "attach", "supa-abc"])
  }

  /// Explicit command (script): wrapped command string and an EMPTY wrapper, so a
  /// script is never double-wrapped via both `command` and a `command-wrapper`.
  @Test func explicitCommandIsStringWrappedWithNoWrapper() {
    let resolved = ZmxAttach.resolveLaunch(executablePath: "/zmx", sessionID: "s", command: "echo hi")
    #expect(resolved.command == "'/zmx' attach s /bin/sh -c 'echo hi'")
    #expect(resolved.commandWrapper.isEmpty)
  }

  /// A blank/whitespace command is normalized to interactive, so it can't slip
  /// into the script path and launch a bare uninteg. shell.
  @Test func blankCommandIsTreatedAsInteractive() {
    let resolved = ZmxAttach.resolveLaunch(executablePath: "/zmx", sessionID: "s", command: "   \n")
    #expect(resolved.command == nil)
    #expect(resolved.commandWrapper == ["/zmx", "attach", "s"])
  }

  /// zmx unbundled / over budget (nil executable): raw command, no zmx at all.
  @Test func nilExecutableFallsThroughToRawCommand() {
    let interactive = ZmxAttach.resolveLaunch(executablePath: nil, sessionID: "s", command: nil)
    #expect(interactive.command == nil)
    #expect(interactive.commandWrapper.isEmpty)

    let script = ZmxAttach.resolveLaunch(executablePath: nil, sessionID: "s", command: "echo hi")
    #expect(script.command == "echo hi")
    #expect(script.commandWrapper.isEmpty)
  }
}

@MainActor
struct ZmxSessionListParserTests {
  @Test func parsesClientsZero() {
    let entries = ZmxSessionListParser.parse("name=supa-abc\tpid=123\tclients=0\tcreated=0\n")
    #expect(entries == [.init(name: "supa-abc", clients: 0)])
  }

  @Test func parsesClientsPositive() {
    let entries = ZmxSessionListParser.parse("name=supa-abc\tpid=123\tclients=2\tcreated=0\n")
    #expect(entries == [.init(name: "supa-abc", clients: 2)])
  }

  @Test func errOrStatusLineYieldsNilClients() {
    let entries = ZmxSessionListParser.parse(
      "name=supa-abc\terr=ConnectionRefused\tstatus=cleaning up\n"
    )
    #expect(entries == [.init(name: "supa-abc", clients: nil)])
  }

  @Test func stripsCurrentSessionArrowPrefix() {
    let entries = ZmxSessionListParser.parse("→ name=supa-abc\tpid=1\tclients=1\tcreated=0\n")
    #expect(entries == [.init(name: "supa-abc", clients: 1)])
  }

  @Test func stripsLeadingIndentOnNonCurrentSessions() {
    let entries = ZmxSessionListParser.parse("  name=supa-abc\tclients=0\tpid=1\tcreated=0\n")
    #expect(entries == [.init(name: "supa-abc", clients: 0)])
  }

  @Test func filtersNonSupaSessions() {
    let entries = ZmxSessionListParser.parse(
      """
      name=dev\tpid=1\tclients=2\tcreated=0
      name=supa-abc\tpid=2\tclients=0\tcreated=0
      """
    )
    #expect(entries == [.init(name: "supa-abc", clients: 0)])
  }

  @Test func dropsBlankAndMalformedLines() {
    let entries = ZmxSessionListParser.parse(
      """

      garbage with no equals
      name=supa-keep\tpid=9\tclients=3\tcreated=0

      """
    )
    #expect(entries == [.init(name: "supa-keep", clients: 3)])
  }
}

@MainActor
struct ZmxClientNoopTests {
  @Test func noopExecutableURLReturnsNil() {
    #expect(ZmxClient.noop.executableURL() == nil)
  }
}

@MainActor
struct ZmxClientKillSurfaceSessionsTests {
  private actor KillRecorder {
    private(set) var calls: [String] = []
    func record(_ call: String) { calls.append(call) }
  }

  private func makeClient(recording recorder: KillRecorder) -> ZmxClient {
    ZmxClient(
      executableURL: { nil },
      isBundled: { true },
      killSession: { _ in await recorder.record("local") },
      killRemoteSession: { _, _ in await recorder.record("remote") },
      listSessionsWithClients: { nil },
    )
  }

  @Test func killsRemoteBeforeLocal() async {
    let recorder = KillRecorder()
    let client = makeClient(recording: recorder)

    await client.killSurfaceSessions(
      sessionID: "supa-s", remoteHost: RemoteHost(alias: "devbox"), killLocal: true)

    #expect(await recorder.calls == ["remote", "local"])
  }

  @Test func skipsRemoteWhenHostUnset() async {
    let recorder = KillRecorder()
    let client = makeClient(recording: recorder)

    await client.killSurfaceSessions(sessionID: "supa-s", remoteHost: nil, killLocal: true)

    #expect(await recorder.calls == ["local"])
  }

  @Test func skipsLocalWhenKillLocalUnset() async {
    let recorder = KillRecorder()
    let client = makeClient(recording: recorder)

    await client.killSurfaceSessions(
      sessionID: "supa-s", remoteHost: RemoteHost(alias: "devbox"), killLocal: false)

    #expect(await recorder.calls == ["remote"])
  }

  @Test func doesNothingWhenBothSidesUnset() async {
    let recorder = KillRecorder()
    let client = makeClient(recording: recorder)

    await client.killSurfaceSessions(sessionID: "supa-s", remoteHost: nil, killLocal: false)

    #expect(await recorder.calls.isEmpty)
  }

  @Test func skipsLocalKillUnderCancellation() async {
    // A budget cancellation mid-remote-kill must not spawn a doomed local kill;
    // the quit path's fallback sweep owns the retry.
    let recorder = KillRecorder()
    let client = makeClient(recording: recorder)

    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      await client.killSurfaceSessions(
        sessionID: "supa-s", remoteHost: RemoteHost(alias: "devbox"), killLocal: true)
    }
    await task.value

    #expect(await recorder.calls == ["remote"])
  }
}
