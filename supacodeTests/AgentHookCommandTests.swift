import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

struct AgentHookCommandTests {
  // MARK: - Command generation.

  @Test func eventCommandEnvelopeContainsEventName() {
    let command = AgentHookSettingsCommand.eventCommand(event: .busy, agent: .claude)
    #expect(command.contains(#"\"event\":\"busy\""#))
  }

  @Test func idleEventCommandEnvelopeContainsIdle() {
    let command = AgentHookSettingsCommand.eventCommand(event: .idle, agent: .claude)
    #expect(command.contains(#"\"event\":\"idle\""#))
  }

  @Test func eventCommandChecksAllFourEnvVars() {
    let command = AgentHookSettingsCommand.eventCommand(event: .busy, agent: .claude)
    #expect(command.contains("SUPACODE_SOCKET_PATH"))
    #expect(command.contains("SUPACODE_WORKTREE_ID"))
    #expect(command.contains("SUPACODE_TAB_ID"))
    #expect(command.contains("SUPACODE_SURFACE_ID"))
  }

  @Test func eventCommandSuppressesErrorsAndCarriesSentinel() {
    let command = AgentHookSettingsCommand.eventCommand(event: .busy, agent: .claude)
    #expect(command.contains(">/dev/null 2>&1 || true"))
    #expect(command.hasSuffix(AgentHookSettingsCommand.ownershipMarker))
  }

  @Test func notificationCommandIncludesAgent() {
    let command = AgentHookSettingsCommand.notificationCommand(agent: .claude)
    #expect(command.contains("claude"))
  }

  @Test func notificationCommandIncludesAllThreeIDs() {
    let command = AgentHookSettingsCommand.notificationCommand(agent: .codex)
    #expect(command.contains("$SUPACODE_WORKTREE_ID"))
    #expect(command.contains("$SUPACODE_TAB_ID"))
    #expect(command.contains("$SUPACODE_SURFACE_ID"))
  }

  // MARK: - Command ownership.

  @Test func currentCommandIsRecognized() {
    let command = AgentHookSettingsCommand.eventCommand(event: .busy, agent: .claude)
    #expect(AgentHookCommandOwnership.isSupacodeManagedCommand(command))
  }

  @Test func notificationCommandIsRecognized() {
    let command = AgentHookSettingsCommand.notificationCommand(agent: .claude)
    #expect(AgentHookCommandOwnership.isSupacodeManagedCommand(command))
  }

  @Test func legacyCommandIsRecognized() {
    let legacy = "SUPACODE_CLI_PATH=/usr/bin/supacode agent-hook --stop"
    #expect(AgentHookCommandOwnership.isSupacodeManagedCommand(legacy))
    #expect(AgentHookCommandOwnership.isLegacyCommand(legacy))
  }

  @Test func legacyCommandRequiresBothMarkers() {
    #expect(!AgentHookCommandOwnership.isLegacyCommand("SUPACODE_CLI_PATH only"))
    #expect(!AgentHookCommandOwnership.isLegacyCommand("agent-hook only"))
  }

  @Test func unrelatedCommandIsNotRecognized() {
    #expect(!AgentHookCommandOwnership.isSupacodeManagedCommand("echo hello"))
    #expect(!AgentHookCommandOwnership.isSupacodeManagedCommand(nil))
  }

  @Test func currentCommandIsNotLegacy() {
    let command = AgentHookSettingsCommand.eventCommand(event: .busy, agent: .claude)
    #expect(!AgentHookCommandOwnership.isLegacyCommand(command))
  }

  @Test func userAuthoredCommandReferencingSocketEnvVarIsNotOwned() {
    // A power user's hook that legitimately references the documented
    // `SUPACODE_SOCKET_PATH` env var must NOT be classified as
    // Supacode-managed, otherwise install would silently strip it.
    let userHook = #"echo "saw $SUPACODE_SOCKET_PATH" >> ~/my-debug.log"#
    #expect(!AgentHookCommandOwnership.isSupacodeManagedCommand(userHook))
    #expect(!AgentHookCommandOwnership.isLegacyCommand(userHook))
  }

  @Test func userAuthoredHookFollowingDocumentedSocketPatternIsNotOwned() {
    // The CLI skill env table and Pi extension docs tell users to write
    // hooks against `SUPACODE_SOCKET_PATH` via `/usr/bin/nc -U`. A
    // user-authored hook following that exact pattern but lacking the
    // sentinel marker must NOT be classified as legacy — otherwise
    // install would silently strip it on the next run.
    let userHook =
      #"[ -n "$SUPACODE_SOCKET_PATH" ] && echo "x" | /usr/bin/nc -U -w1 "$SUPACODE_SOCKET_PATH" || true"#
    #expect(!AgentHookCommandOwnership.isSupacodeManagedCommand(userHook))
    #expect(!AgentHookCommandOwnership.isLegacyCommand(userHook))
  }

  @Test func legacyCLIShimSessionEventCommandIsRecognized() {
    // The transitional shape (between the agent-hook CLI era and the
    // direct-nc era) shelled out to `supacode integration event`.
    // Strip-on-update must still recognise it as Supacode-managed,
    // otherwise the canonical hook is appended on top instead of
    // replacing it — producing duplicate SessionStart hooks.
    let legacy =
      #"[ -n "${SUPACODE_SOCKET_PATH:-}" ] && supacode integration event session_start"#
      + #" --agent claude --pid "$PPID" 2>/dev/null || true"#
    #expect(AgentHookCommandOwnership.isSupacodeManagedCommand(legacy))
    #expect(AgentHookCommandOwnership.isLegacyCommand(legacy))
  }

  @Test func managedCommandSilencesStdoutAndStderr() {
    // Codex parses SessionStart hook stdout as structured JSON output
    // and rejects anything that doesn't match its hook output schema —
    // so the `{"ok":true}` ack the socket server writes back through
    // `nc` would fail the run. Hook commands must redirect both
    // streams to /dev/null.
    let busy = AgentHookSettingsCommand.eventCommand(event: .busy, agent: .claude)
    let session = AgentHookSettingsCommand.eventCommand(event: .sessionStart, agent: .claude)
    #expect(busy.contains(">/dev/null 2>&1"))
    #expect(session.contains(">/dev/null 2>&1"))
  }

  // MARK: - Shared constants consistency.

  @Test func socketPathEnvVarPresentInGeneratedCommands() {
    let busy = AgentHookSettingsCommand.eventCommand(event: .busy, agent: .claude)
    let notify = AgentHookSettingsCommand.notificationCommand(agent: .claude)
    #expect(busy.contains(AgentHookSettingsCommand.socketPathEnvVar))
    #expect(notify.contains(AgentHookSettingsCommand.socketPathEnvVar))
  }

  // MARK: - Envelope round-trip.

  /// Executes the command in a real shell with all required env vars set
  /// and a fake `nc` on PATH that captures stdin to a file. Verifies the
  /// JSON the hook produced is parseable by the same code that consumes
  /// it on the socket — a regression guard against future Swift changes
  /// that subtly break the envelope template.
  @Test func eventCommandProducesParseableJSON() throws {
    let surfaceID = UUID()
    let agentPid: pid_t = getpid()
    let captured = try runHookCommandCapturingStdin(
      AgentHookSettingsCommand.eventCommand(event: .sessionStart, agent: .claude),
      env: [
        "SUPACODE_SOCKET_PATH": "/tmp/supacode-roundtrip-\(UUID().uuidString)",
        "SUPACODE_WORKTREE_ID": "/some/worktree",
        "SUPACODE_TAB_ID": UUID().uuidString,
        "SUPACODE_SURFACE_ID": surfaceID.uuidString,
      ]
    )
    guard case .event(let parsed) = AgentHookSocketServer.parse(data: captured) else {
      Issue.record("Expected parser to recognise envelope; got nil/non-event from \(captured.count) bytes")
      return
    }
    #expect(parsed.eventName == .sessionStart)
    #expect(parsed.agent == "claude")
    #expect(parsed.surfaceID == surfaceID)
    // PPID inside the shell is whatever spawned it (Process), not the
    // test's pid — so just check it's positive and decodes cleanly.
    #expect((parsed.pid ?? 0) > 0)
  }

  /// Run `command` via `/bin/zsh -c`, with a stub `nc` on PATH that
  /// dumps its stdin to a temp file. Returns the captured stdin bytes.
  private func runHookCommandCapturingStdin(
    _ command: String, env: [String: String]
  ) throws -> Data {
    let workDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("supacode-hook-rt-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workDir) }

    // Stub nc that ignores its args (e.g. `-U -w1 <socket>`) and writes
    // stdin to ./capture so we can read the JSON the hook produced.
    let stubBin = workDir.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: stubBin, withIntermediateDirectories: true)
    let stubNC = stubBin.appendingPathComponent("nc")
    let captureFile = workDir.appendingPathComponent("capture")
    try "#!/bin/sh\ncat > '\(captureFile.path)'\n".write(to: stubNC, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stubNC.path)

    // The hook hard-codes `/usr/bin/nc`, so symlink that path target
    // into a private prefix. We cheat by patching the command string
    // for this test to call the stub instead.
    let patched = command.replacing("/usr/bin/nc", with: stubNC.path)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-c", patched]
    var environment = ProcessInfo.processInfo.environment
    for (key, value) in env { environment[key] = value }
    process.environment = environment
    try process.run()
    process.waitUntilExit()

    return (try? Data(contentsOf: captureFile)) ?? Data()
  }
}
