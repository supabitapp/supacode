import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

struct AgentHookCommandTests {
  // MARK: - Command generation.

  @Test func compositeEnvelopeContainsEventName() {
    let command = AgentHookSettingsCommand.compositeCommand(
      events: [.busy], forwardStdinAsNotification: false, agent: .claude)
    #expect(command.contains(#"\"event\":\"busy\""#))
  }

  @Test func compositeIdleEnvelopeContainsIdle() {
    let command = AgentHookSettingsCommand.compositeCommand(
      events: [.idle], forwardStdinAsNotification: false, agent: .claude)
    #expect(command.contains(#"\"event\":\"idle\""#))
  }

  @Test func compositeChecksAllFourEnvVars() {
    let command = AgentHookSettingsCommand.compositeCommand(
      events: [.busy], forwardStdinAsNotification: false, agent: .claude)
    #expect(command.contains("SUPACODE_SOCKET_PATH"))
    #expect(command.contains("SUPACODE_WORKTREE_ID"))
    #expect(command.contains("SUPACODE_TAB_ID"))
    #expect(command.contains("SUPACODE_SURFACE_ID"))
  }

  @Test func compositeSuppressesErrorsAndCarriesSentinel() {
    let command = AgentHookSettingsCommand.compositeCommand(
      events: [.busy], forwardStdinAsNotification: false, agent: .claude)
    #expect(command.contains(">/dev/null 2>&1 || true"))
    #expect(command.hasSuffix(AgentHookSettingsCommand.ownershipMarker))
  }

  @Test func compositeNotifyIncludesAgent() {
    let command = AgentHookSettingsCommand.compositeCommand(
      events: [], forwardStdinAsNotification: true, agent: .claude)
    #expect(command.contains("claude"))
  }

  @Test func compositeNotifyIncludesAllThreeIDs() {
    let command = AgentHookSettingsCommand.compositeCommand(events: [], forwardStdinAsNotification: true, agent: .codex)
    #expect(command.contains("$SUPACODE_WORKTREE_ID"))
    #expect(command.contains("$SUPACODE_TAB_ID"))
    #expect(command.contains("$SUPACODE_SURFACE_ID"))
  }

  // MARK: - Command ownership.

  @Test func currentCommandIsRecognized() {
    let command = AgentHookSettingsCommand.compositeCommand(
      events: [.busy], forwardStdinAsNotification: false, agent: .claude)
    #expect(AgentHookCommandOwnership.isSupacodeManagedCommand(command))
  }

  @Test func compositeNotifyIsRecognized() {
    let command = AgentHookSettingsCommand.compositeCommand(
      events: [], forwardStdinAsNotification: true, agent: .claude)
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
    let command = AgentHookSettingsCommand.compositeCommand(
      events: [.busy], forwardStdinAsNotification: false, agent: .claude)
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

  @Test func verbatimEnvCheckGuardWithoutSentinelIsLegacy() {
    // Lock the intent of the `envCheck` fingerprint: a command that
    // carries the verbatim 4-var guard but lacks the sentinel is a
    // pre-sentinel Supacode hook and must be pruned on install/uninstall.
    let legacy =
      AgentHookSettingsCommand.envCheck
      + #" && echo "$SUPACODE_WORKTREE_ID $SUPACODE_TAB_ID $SUPACODE_SURFACE_ID 0""#
      + #" | /usr/bin/nc -U -w1 "$SUPACODE_SOCKET_PATH" 2>/dev/null || true"#
    #expect(AgentHookCommandOwnership.isLegacyCommand(legacy))
    #expect(AgentHookCommandOwnership.isSupacodeManagedCommand(legacy))
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
    let busy = AgentHookSettingsCommand.compositeCommand(
      events: [.busy], forwardStdinAsNotification: false, agent: .claude)
    let session = AgentHookSettingsCommand.compositeCommand(
      events: [.sessionStart], forwardStdinAsNotification: false, agent: .claude)
    #expect(busy.contains(">/dev/null 2>&1"))
    #expect(session.contains(">/dev/null 2>&1"))
  }

  // MARK: - Shared constants consistency.

  @Test func socketPathEnvVarPresentInGeneratedCommands() {
    let busy = AgentHookSettingsCommand.compositeCommand(
      events: [.busy], forwardStdinAsNotification: false, agent: .claude)
    let notify = AgentHookSettingsCommand.compositeCommand(events: [], forwardStdinAsNotification: true, agent: .claude)
    #expect(busy.contains(AgentHookSettingsCommand.socketPathEnvVar))
    #expect(notify.contains(AgentHookSettingsCommand.socketPathEnvVar))
  }

  // MARK: - compositeCommand branches.

  @Test func compositeMultiEventWrapsInBraceGroupAndPreservesOrder() {
    let composite = AgentHookSettingsCommand.compositeCommand(
      events: [.sessionEnd, .idle], forwardStdinAsNotification: false, agent: .claude
    )
    #expect(composite.contains(#"\"event\":\"session_end\""#))
    #expect(composite.contains(#"\"event\":\"idle\""#))
    #expect(composite.contains("{ printf"))
    #expect(composite.contains("; }"))
    // Order matters: session_end envelope is emitted before idle so the
    // socket server sees the lifecycle close-out before the activity reset.
    let sessionEndIdx = composite.range(of: "session_end")?.lowerBound
    let idleIdx = composite.range(of: #"\"event\":\"idle\""#)?.lowerBound
    if let sessionEndIdx, let idleIdx {
      #expect(sessionEndIdx < idleIdx)
    }
  }

  @Test func compositeEventsPlusNotifyStashesStdinBeforeEmittingEnvelopes() {
    let composite = AgentHookSettingsCommand.compositeCommand(
      events: [.idle], forwardStdinAsNotification: true, agent: .claude
    )
    #expect(composite.contains("payload=$(cat)"))
    #expect(composite.contains(#"printf '%s' "$payload""#))
    let stashIdx = composite.range(of: "payload=$(cat)")?.lowerBound
    let envelopeIdx = composite.range(of: #"\"event\":\"idle\""#)?.lowerBound
    if let stashIdx, let envelopeIdx {
      #expect(stashIdx < envelopeIdx)
    }
  }

  // MARK: - compositeCommand byte-stability snapshots.

  // Lock the exact on-disk command string per (events, forwardStdin, agent)
  // tuple. `installState` compares actual vs expected by byte-equality, so
  // any unintentional shape change here flips every existing install to
  // `.outdated` on the next refresh and auto-update silently rewrites the
  // file. Failures here mean: confirm the change is intentional, then
  // update the snapshot.
  @Test func compositeByteSnapshot_claudeBusy() {
    let composite = AgentHookSettingsCommand.compositeCommand(
      events: [.busy], forwardStdinAsNotification: false, agent: .claude
    )
    let expected =
      #"[ -n "${SUPACODE_SOCKET_PATH:-}" ] && [ -n "${SUPACODE_WORKTREE_ID:-}" ] "#
      + #"&& [ -n "${SUPACODE_TAB_ID:-}" ] && [ -n "${SUPACODE_SURFACE_ID:-}" ] && "#
      + #"printf '%s' "{\"event\":\"busy\",\"v\":1,\"agent\":\"claude\","#
      + #"\"surface_id\":\"$SUPACODE_SURFACE_ID\",\"pid\":$PPID}" "#
      + #"| /usr/bin/nc -U -w1 "$SUPACODE_SOCKET_PATH" >/dev/null 2>&1 || true # supacode-managed-hook"#
    #expect(composite == expected)
  }

  @Test func compositeByteSnapshot_claudeStopIdleAndNotify() {
    let composite = AgentHookSettingsCommand.compositeCommand(
      events: [.idle], forwardStdinAsNotification: true, agent: .claude
    )
    let expected =
      #"[ -n "${SUPACODE_SOCKET_PATH:-}" ] && [ -n "${SUPACODE_WORKTREE_ID:-}" ] "#
      + #"&& [ -n "${SUPACODE_TAB_ID:-}" ] && [ -n "${SUPACODE_SURFACE_ID:-}" ] && "#
      + #"{ payload=$(cat); "#
      + #"printf '%s' "{\"event\":\"idle\",\"v\":1,\"agent\":\"claude\","#
      + #"\"surface_id\":\"$SUPACODE_SURFACE_ID\",\"pid\":$PPID}" "#
      + #"| /usr/bin/nc -U -w1 "$SUPACODE_SOCKET_PATH"; "#
      + #"{ printf '%s claude\n' "$SUPACODE_WORKTREE_ID $SUPACODE_TAB_ID $SUPACODE_SURFACE_ID"; "#
      + #"printf '%s' "$payload"; } "#
      + #"| /usr/bin/nc -U -w1 "$SUPACODE_SOCKET_PATH"; } >/dev/null 2>&1 || true # supacode-managed-hook"#
    #expect(composite == expected)
  }

  @Test func compositeByteSnapshot_claudeSessionEndAndIdle() {
    // Multi-event branch with no stdin forward — covers the brace-grouped
    // shape used by Claude `SessionEnd`. Without this, a refactor of the
    // multi-event template silently flips every existing install to
    // `.outdated` and auto-update rewrites every settings.json.
    let composite = AgentHookSettingsCommand.compositeCommand(
      events: [.sessionEnd, .idle], forwardStdinAsNotification: false, agent: .claude
    )
    let expected =
      #"[ -n "${SUPACODE_SOCKET_PATH:-}" ] && [ -n "${SUPACODE_WORKTREE_ID:-}" ] "#
      + #"&& [ -n "${SUPACODE_TAB_ID:-}" ] && [ -n "${SUPACODE_SURFACE_ID:-}" ] && "#
      + #"{ printf '%s' "{\"event\":\"session_end\",\"v\":1,\"agent\":\"claude\","#
      + #"\"surface_id\":\"$SUPACODE_SURFACE_ID\",\"pid\":$PPID}" "#
      + #"| /usr/bin/nc -U -w1 "$SUPACODE_SOCKET_PATH"; "#
      + #"printf '%s' "{\"event\":\"idle\",\"v\":1,\"agent\":\"claude\","#
      + #"\"surface_id\":\"$SUPACODE_SURFACE_ID\",\"pid\":$PPID}" "#
      + #"| /usr/bin/nc -U -w1 "$SUPACODE_SOCKET_PATH"; } >/dev/null 2>&1 || true # supacode-managed-hook"#
    #expect(composite == expected)
  }

  @Test func compositeByteSnapshot_codexStopIdleAndNotify() {
    // Per-agent templating parity — a refactor of `\(agent.rawValue)` in
    // the envelope or notify pipeline could regress Codex/Kiro without
    // tripping the Claude snapshots.
    let composite = AgentHookSettingsCommand.compositeCommand(
      events: [.idle], forwardStdinAsNotification: true, agent: .codex
    )
    let expected =
      #"[ -n "${SUPACODE_SOCKET_PATH:-}" ] && [ -n "${SUPACODE_WORKTREE_ID:-}" ] "#
      + #"&& [ -n "${SUPACODE_TAB_ID:-}" ] && [ -n "${SUPACODE_SURFACE_ID:-}" ] && "#
      + #"{ payload=$(cat); "#
      + #"printf '%s' "{\"event\":\"idle\",\"v\":1,\"agent\":\"codex\","#
      + #"\"surface_id\":\"$SUPACODE_SURFACE_ID\",\"pid\":$PPID}" "#
      + #"| /usr/bin/nc -U -w1 "$SUPACODE_SOCKET_PATH"; "#
      + #"{ printf '%s codex\n' "$SUPACODE_WORKTREE_ID $SUPACODE_TAB_ID $SUPACODE_SURFACE_ID"; "#
      + #"printf '%s' "$payload"; } "#
      + #"| /usr/bin/nc -U -w1 "$SUPACODE_SOCKET_PATH"; } >/dev/null 2>&1 || true # supacode-managed-hook"#
    #expect(composite == expected)
  }

  @Test func compositeByteSnapshot_kiroStopIdleAndNotify() {
    let composite = AgentHookSettingsCommand.compositeCommand(
      events: [.idle], forwardStdinAsNotification: true, agent: .kiro
    )
    let expected =
      #"[ -n "${SUPACODE_SOCKET_PATH:-}" ] && [ -n "${SUPACODE_WORKTREE_ID:-}" ] "#
      + #"&& [ -n "${SUPACODE_TAB_ID:-}" ] && [ -n "${SUPACODE_SURFACE_ID:-}" ] && "#
      + #"{ payload=$(cat); "#
      + #"printf '%s' "{\"event\":\"idle\",\"v\":1,\"agent\":\"kiro\","#
      + #"\"surface_id\":\"$SUPACODE_SURFACE_ID\",\"pid\":$PPID}" "#
      + #"| /usr/bin/nc -U -w1 "$SUPACODE_SOCKET_PATH"; "#
      + #"{ printf '%s kiro\n' "$SUPACODE_WORKTREE_ID $SUPACODE_TAB_ID $SUPACODE_SURFACE_ID"; "#
      + #"printf '%s' "$payload"; } "#
      + #"| /usr/bin/nc -U -w1 "$SUPACODE_SOCKET_PATH"; } >/dev/null 2>&1 || true # supacode-managed-hook"#
    #expect(composite == expected)
  }

  // MARK: - Envelope round-trip.

  /// Executes the command in a real shell with all required env vars set
  /// and a fake `nc` on PATH that captures stdin to a file. Verifies the
  /// JSON the hook produced is parseable by the same code that consumes
  /// it on the socket — a regression guard against future Swift changes
  /// that subtly break the envelope template.
  @Test func compositeEnvelopeProducesParseableJSON() throws {
    let surfaceID = UUID()
    let agentPid: pid_t = getpid()
    let captured = try runHookCommandCapturingStdin(
      AgentHookSettingsCommand.compositeCommand(
        events: [.sessionStart], forwardStdinAsNotification: false, agent: .claude),
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

  /// Composite shell roundtrip for `forwardStdinAsNotification: true`:
  /// pipes representative Claude `Stop` JSON through the `idle + notify`
  /// composite, captures both `nc -U` writes, and asserts the parser
  /// recognises the first as an idle event and the second as a notification.
  @Test func compositeIdleAndNotifyProducesParseableEventThenNotification() throws {
    let surfaceID = UUID()
    let stopPayload =
      #"{"stop_hook_active":false,"hook_event_name":"Stop","last_assistant_message":"Done."}"#
    let captures = try runHookCommandCapturingMultipleStdin(
      AgentHookSettingsCommand.compositeCommand(
        events: [.idle], forwardStdinAsNotification: true, agent: .claude
      ),
      stdin: stopPayload,
      env: [
        "SUPACODE_SOCKET_PATH": "/tmp/supacode-rt-\(UUID().uuidString)",
        "SUPACODE_WORKTREE_ID": "/some/worktree",
        "SUPACODE_TAB_ID": UUID().uuidString,
        "SUPACODE_SURFACE_ID": surfaceID.uuidString,
      ]
    )
    #expect(captures.count == 2)
    guard captures.count == 2 else { return }
    guard case .event(let event) = AgentHookSocketServer.parse(data: captures[0]) else {
      Issue.record("Expected first capture to be an idle event envelope")
      return
    }
    #expect(event.eventName == .idle)
    #expect(event.surfaceID == surfaceID)
    guard
      case .notification(_, _, let notifSurfaceID, let notification) = AgentHookSocketServer.parse(data: captures[1])
    else {
      Issue.record("Expected second capture to be a notification (header + payload)")
      return
    }
    #expect(notification.agent == "claude")
    #expect(notifSurfaceID == surfaceID)
    // The notification body decodes from `last_assistant_message` — confirms
    // `$(cat)` preserved the payload across the brace-grouped pipeline.
    #expect(notification.body == "Done.")
  }

  /// Multi-nc variant of `runHookCommandCapturingStdin`. The stub appends
  /// each invocation's stdin to a single file separated by a sentinel
  /// line, then we split on the sentinel to return one `Data` per `nc`.
  private func runHookCommandCapturingMultipleStdin(
    _ command: String, stdin: String, env: [String: String]
  ) throws -> [Data] {
    let workDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("supacode-hook-multi-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workDir) }
    let stubBin = workDir.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: stubBin, withIntermediateDirectories: true)
    let stubNC = stubBin.appendingPathComponent("nc")
    let captureFile = workDir.appendingPathComponent("capture")
    let boundary = "---NC-CAPTURE-BOUNDARY---"
    try "#!/bin/sh\ncat >> '\(captureFile.path)'\nprintf '\\n\(boundary)\\n' >> '\(captureFile.path)'\n"
      .write(to: stubNC, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stubNC.path)
    let patched = command.replacing("/usr/bin/nc", with: stubNC.path)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-c", patched]
    var environment = ProcessInfo.processInfo.environment
    for (key, value) in env { environment[key] = value }
    process.environment = environment
    let stdinPipe = Pipe()
    process.standardInput = stdinPipe
    try process.run()
    stdinPipe.fileHandleForWriting.write(Data(stdin.utf8))
    try? stdinPipe.fileHandleForWriting.close()
    process.waitUntilExit()

    let raw = (try? Data(contentsOf: captureFile)) ?? Data()
    guard let text = String(data: raw, encoding: .utf8) else { return [] }
    return text.components(separatedBy: "\n\(boundary)\n")
      .dropLast()  // trailing element after the last boundary is empty.
      .map { Data($0.utf8) }
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
