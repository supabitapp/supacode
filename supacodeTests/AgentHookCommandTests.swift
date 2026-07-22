import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

struct AgentHookCommandTests {
  // MARK: - Command generation.

  @Test func compositeBusyCarriesOSCBusyEvent() {
    let command = AgentHookSettingsCommand.compositeCommand(
      events: [.busy], forwardStdinAsNotification: false, agent: .claude)
    #expect(command.contains("event=busy"))
  }

  @Test func compositeIdleCarriesOSCIdleEvent() {
    let command = AgentHookSettingsCommand.compositeCommand(
      events: [.idle], forwardStdinAsNotification: false, agent: .claude)
    #expect(command.contains("event=idle"))
  }

  // MARK: - AgentCommandHook env encoding.

  @Test func commandHookOmitsEnvWhenNil() throws {
    let encoded = try Self.encodeHook(.init(command: "run", timeout: 5))
    #expect(encoded["env"] == nil)
  }

  @Test func commandHookOmitsEnvWhenEmpty() throws {
    // An empty map must not serialize as `"env": {}`, so agents without a
    // passthrough (Claude, Codex) keep their bare hook shape.
    let encoded = try Self.encodeHook(.init(command: "run", timeout: 5, env: [:]))
    #expect(encoded["env"] == nil)
  }

  @Test func commandHookEncodesNonEmptyEnv() throws {
    let encoded = try Self.encodeHook(
      .init(command: "run", timeout: 5, env: ["SUPACODE_SURFACE_ID": "${SUPACODE_SURFACE_ID}"]))
    #expect(encoded["env"]?.objectValue?["SUPACODE_SURFACE_ID"]?.stringValue == "${SUPACODE_SURFACE_ID}")
  }

  private static func encodeHook(_ hook: AgentCommandHook) throws -> [String: JSONValue] {
    let data = try JSONEncoder().encode(hook)
    return try JSONDecoder().decode(JSONValue.self, from: data).objectValue ?? [:]
  }

  // MARK: - Claude canonical hook map.

  @Test func claudePostToolUseFiresIdleNotBusy() throws {
    // PostToolUse releases the shimmer when a tool finishes, so `busy` tracks
    // active tool execution rather than the whole turn.
    let groups = try ClaudeHookSettings.hooksByEvent()
    let postToolUse = try #require(groups["PostToolUse"])
    let commands = Self.commandStrings(in: postToolUse)
    #expect(!commands.isEmpty)
    #expect(commands.allSatisfy { $0.contains("event=idle") })
    #expect(commands.allSatisfy { !$0.contains("event=busy") })
  }

  @Test func claudePreToolUseOrdersAwaitingAfterBusy() throws {
    // Order is load-bearing: the "" matcher (busy) must precede the
    // AskUserQuestion / ExitPlanMode matcher (awaiting) so the named match fires
    // last and wins, keeping a permission / plan prompt from shimmering under
    // busy-only hasActivity. Assert by index, not by predicate.
    let groups = try ClaudeHookSettings.hooksByEvent()
    let preToolUse = try #require(groups["PreToolUse"])
    #expect(preToolUse.count == 2)

    let first = try #require(preToolUse.first)
    #expect(first.objectValue?["matcher"]?.stringValue == "")
    let firstCommand = try #require(Self.commandStrings(in: [first]).first)
    #expect(firstCommand.contains("event=busy"))

    let second = try #require(preToolUse.last)
    #expect(second.objectValue?["matcher"]?.stringValue == "AskUserQuestion|ExitPlanMode")
    let secondCommand = try #require(Self.commandStrings(in: [second]).first)
    #expect(secondCommand.contains("event=awaiting_input"))
  }

  private static func commandStrings(in groups: [JSONValue]) -> [String] {
    groups.flatMap { group in
      group.objectValue?["hooks"]?.arrayValue?.compactMap {
        $0.objectValue?["command"]?.stringValue
      } ?? []
    }
  }

  // MARK: - Error + compaction events.

  @Test func everyHookEventDecodesOnTheAppSide() {
    // The emitter and the app carry parallel enums; an event only the emitter knows
    // about lands on the wire and is silently dropped.
    for event in HookEvent.allCases {
      #expect(AgentHookEvent.EventName(rawValue: event.rawValue) != nil)
    }
  }

  @Test func emitShellErrorCarriesOSCErrorEvent() {
    let command = AgentPresenceOSC.emitShell(event: .error, agent: .claude)
    #expect(command.contains("event=error"))
  }

  @Test func compositeCompactingCarriesOSCCompactingEvent() {
    let command = AgentHookSettingsCommand.compositeCommand(
      events: [.compacting], forwardStdinAsNotification: false, agent: .claude)
    #expect(command.contains("event=compacting"))
  }

  @Test func claudePreCompactMapsToCompactingAndPostCompactIsUnmapped() throws {
    // PostCompact is intentionally NOT mapped: compaction finishing is not turn
    // completion. The SessionStart Claude fires afterwards is what ends the state.
    let groups = try ClaudeHookSettings.hooksByEvent()
    let preCompact = try #require(groups["PreCompact"])
    let commands = Self.commandStrings(in: preCompact)
    #expect(!commands.isEmpty)
    #expect(commands.allSatisfy { $0.contains("event=compacting") })
    #expect(groups["PostCompact"] == nil)
  }

  @Test func claudeStopProbesTranscriptForErrorButStillIdlesOtherwise() throws {
    // Both branches must be present, plus the notify leg.
    let groups = try ClaudeHookSettings.hooksByEvent()
    let stop = try #require(groups["Stop"])
    let command = try #require(Self.commandStrings(in: stop).first)
    #expect(command.contains("transcript_path"))
    #expect(command.contains("isApiErrorMessage"))
    #expect(command.contains("event=error"))
    #expect(command.contains("event=idle"))
    #expect(command.contains("kind=notify"))
    // SSH portability: no jq / python in the transcript probe.
    #expect(!command.contains("jq"))
    #expect(!command.contains("python"))
  }

  @Test func compositeGuardsOnSurfaceOnly() {
    // OSC is the only transport now, and signals are unauthenticated: the guard
    // is just the surface id (the no-op-outside-Supacode gate). The token and the
    // worktree / tab ids the socket envelope carried are gone.
    let command = AgentHookSettingsCommand.compositeCommand(
      events: [.busy], forwardStdinAsNotification: false, agent: .claude)
    #expect(command.contains("SUPACODE_SURFACE_ID"))
    #expect(!command.contains("SUPACODE_OSC_TOKEN"))
    #expect(!command.contains("token="))
    #expect(!command.contains("SUPACODE_WORKTREE_ID"))
    #expect(!command.contains("SUPACODE_TAB_ID"))
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

  @Test func notifyDoesNotReferenceWorktreeOrTabIDs() {
    // The notify leg used to prefix a `worktree tab surface agent` header for
    // the socket text proto. The OSC notify carries only base64 title/body, so
    // those ids must be gone; only the surface-id gate remains.
    let command = AgentHookSettingsCommand.compositeCommand(
      events: [], forwardStdinAsNotification: true, agent: .codex)
    #expect(!command.contains("SUPACODE_WORKTREE_ID"))
    #expect(!command.contains("SUPACODE_TAB_ID"))
    #expect(command.contains("SUPACODE_SURFACE_ID"))
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
    // A user-authored hook that talks to the socket via `/usr/bin/nc -U` but
    // lacks the sentinel marker must NOT be classified as legacy. Otherwise
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
    // replacing it, producing duplicate SessionStart hooks.
    let legacy =
      #"[ -n "${SUPACODE_SOCKET_PATH:-}" ] && supacode integration event session_start"#
      + #" --agent claude --pid "$PPID" 2>/dev/null || true"#
    #expect(AgentHookCommandOwnership.isSupacodeManagedCommand(legacy))
    #expect(AgentHookCommandOwnership.isLegacyCommand(legacy))
  }

  @Test func managedCommandSilencesStdoutAndStderr() {
    // Codex parses SessionStart hook stdout as structured JSON output and
    // rejects anything that doesn't match its hook output schema, so the OSC
    // escape bytes must never leak onto stdout. Hook commands redirect both
    // streams to /dev/null (the OSC itself goes straight to /dev/tty).
    let busy = AgentHookSettingsCommand.compositeCommand(
      events: [.busy], forwardStdinAsNotification: false, agent: .claude)
    let session = AgentHookSettingsCommand.compositeCommand(
      events: [.sessionStart], forwardStdinAsNotification: false, agent: .claude)
    #expect(busy.contains(">/dev/null 2>&1"))
    #expect(session.contains(">/dev/null 2>&1"))
  }

  // MARK: - Shared constants consistency.

  @Test func socketPathGatesThePresencePidSuffixOnly() {
    // `SUPACODE_SOCKET_PATH` survives in the command solely as the local-host
    // gate for the pid suffix on presence; the notify-only command (no pid)
    // never references it.
    let presence = AgentHookSettingsCommand.compositeCommand(
      events: [.busy], forwardStdinAsNotification: false, agent: .claude)
    let notifyOnly = AgentHookSettingsCommand.compositeCommand(
      events: [], forwardStdinAsNotification: true, agent: .claude)
    #expect(presence.contains(AgentHookSettingsCommand.socketPathEnvVar))
    #expect(!notifyOnly.contains(AgentHookSettingsCommand.socketPathEnvVar))
  }

  // MARK: - compositeCommand branches.

  @Test func compositeMultiEventWrapsInBraceGroupAndPreservesOrder() {
    let composite = AgentHookSettingsCommand.compositeCommand(
      events: [.sessionEnd, .idle], forwardStdinAsNotification: false, agent: .claude
    )
    #expect(composite.contains("event=session_end"))
    #expect(composite.contains("event=idle"))
    // Both presence emits live inside one guarded brace group that closes before
    // the error-suppression tail.
    #expect(composite.contains("&& { __ppid="))
    #expect(composite.contains("; } >/dev/null 2>&1 || true"))
    // Order matters: the session_end presence is emitted before idle so the app
    // sees the lifecycle close-out before the activity reset.
    let sessionEndIdx = composite.range(of: "event=session_end")?.lowerBound
    let idleIdx = composite.range(of: "event=idle")?.lowerBound
    if let sessionEndIdx, let idleIdx {
      #expect(sessionEndIdx < idleIdx)
    }
  }

  @Test func compositeEventsPlusNotifyEmitsPresenceBeforeNotify() {
    let composite = AgentHookSettingsCommand.compositeCommand(
      events: [.idle], forwardStdinAsNotification: true, agent: .claude
    )
    #expect(composite.contains("event=idle"))
    #expect(composite.contains("kind=notify"))
    let presenceIdx = composite.range(of: "event=idle")?.lowerBound
    let notifyIdx = composite.range(of: "kind=notify")?.lowerBound
    if let presenceIdx, let notifyIdx {
      #expect(presenceIdx < notifyIdx)
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
    let expected = Self.snapshotClaudeBusy
    #expect(composite == expected)
  }

  @Test func compositeByteSnapshot_claudeIdleAndNotify() {
    let composite = AgentHookSettingsCommand.compositeCommand(
      events: [.idle], forwardStdinAsNotification: true, agent: .claude
    )
    #expect(composite == Self.snapshotClaudeIdleAndNotify)
  }

  @Test func compositeByteSnapshot_claudeSessionEndAndIdle() {
    let composite = AgentHookSettingsCommand.compositeCommand(
      events: [.sessionEnd, .idle], forwardStdinAsNotification: false, agent: .claude
    )
    #expect(composite == Self.snapshotClaudeSessionEndAndIdle)
  }

  @Test func compositeByteSnapshot_codexIdleAndNotify() {
    let composite = AgentHookSettingsCommand.compositeCommand(
      events: [.idle], forwardStdinAsNotification: true, agent: .codex
    )
    #expect(composite == Self.snapshotCodexIdleAndNotify)
  }

  @Test func compositeByteSnapshot_kiroIdleAndNotify() {
    let composite = AgentHookSettingsCommand.compositeCommand(
      events: [.idle], forwardStdinAsNotification: true, agent: .kiro
    )
    #expect(composite == Self.snapshotKiroIdleAndNotify)
  }

  @Test func compositeByteSnapshot_opencodeSessionEndAndIdle() {
    // The plugin's `dispose` hook emits session_end + idle; lock its shape.
    let composite = AgentHookSettingsCommand.compositeCommand(
      events: [.sessionEnd, .idle], forwardStdinAsNotification: false, agent: .opencode
    )
    #expect(composite == Self.snapshotOpencodeSessionEndAndIdle)
  }

  @Test func compositeByteSnapshot_opencodeBusy() {
    let composite = AgentHookSettingsCommand.compositeCommand(
      events: [.busy], forwardStdinAsNotification: false, agent: .opencode
    )
    #expect(composite == Self.snapshotOpencodeBusy)
  }

  /// Cross-check against a fully-inlined literal so a refactor that drifts both
  /// the production code AND the `presence` / `guardAndTTY` helpers cannot
  /// pass byte-stability. The other snapshots compose from helpers that mirror
  /// the production code structure, so they only catch drift if exactly one
  /// side moves.
  @Test func compositeByteSnapshot_claudeBusy_inlineLiteral() {
    let composite = AgentHookSettingsCommand.compositeCommand(
      events: [.busy], forwardStdinAsNotification: false, agent: .claude
    )
    let expected =
      #"[ -n "${SUPACODE_SURFACE_ID:-}" ] && { "#
      + #"__ppid=$(ps -o ppid= -p $$ 2>/dev/null | tr -d '[:space:]'); "#
      + #"__tty=$(ps -o tty= -p "$__ppid" 2>/dev/null | tr -d '[:space:]'); "#
      + #"case "$__tty" in *[0-9]*) __tty="/dev/${__tty#/dev/}";; *) __tty="/dev/tty";; esac; "#
      + #"__sp=""; [ -n "${SUPACODE_SOCKET_PATH:-}" ] && [ -n "$__ppid" ] "#
      + #"&& __sp=";pid=$__ppid"; "#
      + #"printf '\033]3008;start=claude;event=busy%s\033\\' "$__sp" > "$__tty"; "#
      + #"} >/dev/null 2>&1 || true # supacode-managed-hook"#
    #expect(composite == expected)
  }

  // MARK: - OSC presence emission.

  @Test func compositeEmitsOSCPresenceGuardedBySurface() {
    let command = AgentHookSettingsCommand.compositeCommand(
      events: [.busy], forwardStdinAsNotification: false, agent: .claude)
    // OSC is the sole transport, gated only by the surface id (no-op outside
    // Supacode). It fires local and remote alike, and carries no token.
    #expect(command.contains("]3008;start=claude;event=busy"))
    #expect(command.contains(#"[ -n "${SUPACODE_SURFACE_ID:-}" ]"#))
    #expect(!command.contains("token="))
    #expect(command.contains(#"> "$__tty""#))
    #expect(command.contains("ps -o tty="))
    #expect(!command.contains(#"[ -z "${SUPACODE_SOCKET_PATH:-}" ]"#))
  }

  @Test func sessionStartComposesOSCPresenceForOSCAgents() {
    for agent in [SkillAgent.claude, .codex, .grok, .opencode] {
      let command = AgentHookSettingsCommand.compositeCommand(
        events: [.sessionStart], forwardStdinAsNotification: false, agent: agent)
      #expect(command.contains("]3008;start=\(agent.rawValue);event=session_start"))
    }
  }

  @Test func sessionEndUsesOSCEndAction() {
    let command = AgentHookSettingsCommand.compositeCommand(
      events: [.sessionEnd, .idle], forwardStdinAsNotification: false, agent: .claude)
    #expect(command.contains("]3008;end=claude;event=session_end"))
  }

  @Test func awaitingInputComposesOSCPresence() {
    // awaiting_input is the badge-critical "needs you" state; assert it rides OSC too.
    let command = AgentHookSettingsCommand.compositeCommand(
      events: [.awaitingInput], forwardStdinAsNotification: false, agent: .claude)
    #expect(command.contains("]3008;start=claude;event=awaiting_input"))
  }

  @Test func notifyOnlyComposesNotifyOSCButNoPresenceOSC() {
    // Notify-only (no events) emits the notify OSC but no presence OSC.
    let command = AgentHookSettingsCommand.compositeCommand(
      events: [], forwardStdinAsNotification: true, agent: .claude)
    #expect(command.contains("]3008;start=claude;kind=notify;"))
    #expect(!command.contains(";event="))
  }

  @Test func notifyComposesOSCNotify() {
    let command = AgentHookSettingsCommand.compositeCommand(
      events: [.idle], forwardStdinAsNotification: true, agent: .claude)
    #expect(command.contains("]3008;start=claude;kind=notify;title=%s;body=%s"))
    #expect(command.contains("base64 | tr -d"))
  }

  @Test func eventOnlyCommandEmitsNoOSCNotify() {
    let command = AgentHookSettingsCommand.compositeCommand(
      events: [.busy], forwardStdinAsNotification: false, agent: .claude)
    #expect(!command.contains("kind=notify"))
  }

  // MARK: - Runtime behaviour (real shell).

  @Test func presenceCarriesLocalPidButNotRemote() async throws {
    // The pid suffix is the local/remote discriminator: present when
    // SUPACODE_SOCKET_PATH is set (local host), absent over SSH. A regression
    // that always or never emitted it would silently break the liveness sweep.
    let base: [String: String] = ["SUPACODE_SURFACE_ID": UUID().uuidString]
    let command = AgentHookSettingsCommand.compositeCommand(
      events: [.busy], forwardStdinAsNotification: false, agent: .claude)

    // Local (socket present): the presence OSC carries a positive pid.
    let local = try await runHookCommandCapturingTTY(
      command, env: base.merging(["SUPACODE_SOCKET_PATH": "/tmp/sock-\(UUID().uuidString)"]) { $1 })
    let localSignal = try #require(Self.parsePresence(fromTTY: local))
    #expect(localSignal.eventRawValue == "busy")
    #expect(localSignal.pid == ProcessInfo.processInfo.processIdentifier)

    // Remote (socket absent): the presence OSC lands but carries no pid.
    let remote = try await runHookCommandCapturingTTY(command, env: base)
    let remoteSignal = try #require(Self.parsePresence(fromTTY: remote))
    #expect(remoteSignal.eventRawValue == "busy")
    #expect(remoteSignal.pid == nil)
  }

  @Test func notifyExtractsBodyFromStdinThroughAwk() async throws {
    // End-to-end: the real shell hook runs the awk extractor over Claude's stdin
    // JSON and the resulting OSC parses back with the body intact.
    let json = #"{"hook_event_name":"Stop","message":"hi there"}"#
    let base: [String: String] = ["SUPACODE_SURFACE_ID": UUID().uuidString]
    let command = AgentHookSettingsCommand.compositeCommand(
      events: [], forwardStdinAsNotification: true, agent: .claude)
    let tty = try await runHookCommandCapturingTTY(command, env: base, stdin: json)
    let signal = try #require(Self.parseNotify(fromTTY: tty))
    #expect(signal.body == "hi there")
  }

  @Test func notifyAwkPreservesEscapedQuotesNewlinesAndUnicode() async throws {
    // The awk extractor must copy the escaped JSON value verbatim so embedded
    // quotes / newlines / unicode survive the round-trip, and pick the body via
    // the precedence list (here `last_assistant_message`, with `message` empty).
    let json =
      #"{"hook_event_name":"Stop","title":"Done","message":"","last_assistant_message":"line \"one\"\nDONE ✓"}"#
    let base: [String: String] = ["SUPACODE_SURFACE_ID": UUID().uuidString]
    let command = AgentHookSettingsCommand.compositeCommand(
      events: [.idle], forwardStdinAsNotification: true, agent: .claude)
    let tty = try await runHookCommandCapturingTTY(command, env: base, stdin: json)
    #expect(tty.contains("]3008;start=claude;event=idle"))
    let signal = try #require(Self.parseNotify(fromTTY: tty))
    #expect(signal.title == "Done")
    #expect(signal.body == "line \"one\"\nDONE ✓")
  }

  @Test(arguments: [
    // message wins over the fallbacks.
    (#"{"message":"primary","last_assistant_message":"secondary","assistant_response":"tertiary"}"#, "primary"),
    // The awk is not type-aware: empty / null / numeric `message` falls through only
    // because `fv` requires an opening `"` after the colon and finds none.
    (#"{"message":"","last_assistant_message":"fallback"}"#, "fallback"),
    (#"{"message":null,"last_assistant_message":"fallback"}"#, "fallback"),
    (#"{"message":42,"assistant_response":"kiro body"}"#, "kiro body"),
    (#"{"assistant_response":"kiro body"}"#, "kiro body"),
  ])
  func notifyAwkResolvesBodyByPrecedence(json: String, expectedBody: String) async throws {
    let base: [String: String] = ["SUPACODE_SURFACE_ID": UUID().uuidString]
    let command = AgentHookSettingsCommand.compositeCommand(
      events: [], forwardStdinAsNotification: true, agent: .claude)
    let tty = try await runHookCommandCapturingTTY(command, env: base, stdin: json)
    let signal = try #require(Self.parseNotify(fromTTY: tty))
    #expect(signal.body == expectedBody)
  }

  @Test func notifyByteCapFiresAndWireStaysUnderOSCCeiling() async throws {
    // Drive a body past notifyBodyByteBudget through the REAL awk and assert the
    // emitted metadata stays under libghostty's 2048-byte OSC ceiling (the headline
    // guarantee) and the decoded body is a sane truncated prefix. Exercises the
    // `length(v)>budget` branch and the LC_ALL=C byte cap end to end.
    let bodyText = String(repeating: "a", count: 4000)
    let json = #"{"hook_event_name":"Stop","message":"\#(bodyText)"}"#
    let base: [String: String] = ["SUPACODE_SURFACE_ID": UUID().uuidString]
    let command = AgentHookSettingsCommand.compositeCommand(
      events: [], forwardStdinAsNotification: true, agent: .claude)
    let tty = try await runHookCommandCapturingTTY(command, env: base, stdin: json)
    // Metadata is everything after `]3008;` up to ST; assert it is under the cap.
    let marker = try #require(tty.range(of: "]3008;"))
    let afterMarker = tty[marker.upperBound...]
    let stRange = try #require(afterMarker.range(of: "\u{1b}\\"))
    #expect(afterMarker[..<stRange.lowerBound].utf8.count < 2048)
    let signal = try #require(Self.parseNotify(fromTTY: tty))
    #expect(signal.body?.isEmpty == false)
    #expect(signal.body?.allSatisfy { $0 == "a" } == true)
  }

  @Test func notifyMultibyteBodyCapDecodesToCleanPrefix() async throws {
    // A multibyte (non-ASCII) body driven past the byte budget is the realistic
    // silent-drop risk for non-English agent output: LC_ALL=C makes the awk cap
    // byte-based, so it can sever a 3-byte codepoint mid-sequence. The shed loop
    // in decodeNotifyValue must recover a clean prefix, not corrupt to U+FFFD or
    // drop the whole body. "日" is 3 bytes, so 2000 of them blow past the 1000-byte
    // budget and the cap lands mid-codepoint.
    let bodyText = String(repeating: "日", count: 2000)
    let json = #"{"hook_event_name":"Stop","message":"\#(bodyText)"}"#
    let base: [String: String] = ["SUPACODE_SURFACE_ID": UUID().uuidString]
    let command = AgentHookSettingsCommand.compositeCommand(
      events: [], forwardStdinAsNotification: true, agent: .claude)
    let tty = try await runHookCommandCapturingTTY(command, env: base, stdin: json)
    let signal = try #require(Self.parseNotify(fromTTY: tty))
    #expect(signal.body?.isEmpty == false)
    // Every surviving character is a whole "日": no partial codepoint, no U+FFFD.
    #expect(signal.body?.allSatisfy { $0 == "日" } == true)
  }

  @Test func notifyAwkIgnoresKeyTextEscapedInsideAnEarlierValue() async throws {
    // The awk matches the first `"message":` occurrence. An earlier value that
    // mentions the key can only do so with escaped quotes (valid JSON), so the
    // `"message"` token (quote-key-quote) never matches inside it: the real
    // top-level field still wins. Pins that JSON escaping protects flat extraction.
    let json = #"{"title":"see \"message\": here","message":"real body"}"#
    let base: [String: String] = ["SUPACODE_SURFACE_ID": UUID().uuidString]
    let command = AgentHookSettingsCommand.compositeCommand(
      events: [], forwardStdinAsNotification: true, agent: .claude)
    let tty = try await runHookCommandCapturingTTY(command, env: base, stdin: json)
    let signal = try #require(Self.parseNotify(fromTTY: tty))
    #expect(signal.title == #"see "message": here"#)
    #expect(signal.body == "real body")
  }

  @Test func emitsNothingOutsideSupacode() async throws {
    // No SUPACODE_SURFACE_ID = not a Supacode surface: the guard short-circuits
    // and the command writes nothing to the tty (the inert-outside-Supacode
    // contract).
    let command = AgentHookSettingsCommand.compositeCommand(
      events: [.busy], forwardStdinAsNotification: true, agent: .claude)
    let tty = try await runHookCommandCapturingTTY(command, env: [:], stdin: "{}")
    #expect(tty.isEmpty)
  }

  // MARK: - Stop-hook error transcript probe (real shell).

  /// One compact transcript entry; `sessionId` defaults to the current turn's.
  private static func transcriptLine(
    type: String, sessionId: String = "S", isApiError: Bool = false
  ) -> String {
    let errorField = isApiError ? #","isApiErrorMessage":true,"error":"server_error""# : ""
    return #"{"type":"\#(type)","sessionId":"\#(sessionId)"\#(errorField),"message":{"role":"\#(type)","content":"x"}}"#
  }

  /// Writes JSONL `lines` to a temp file and returns its path (caller cleans up).
  private func writeTranscript(_ lines: [String]) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("supacode-transcript-\(UUID().uuidString).jsonl")
    try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  /// Runs the Claude Stop hook with a stdin payload pointing at `transcriptPath`
  /// and returns the captured tty text. `transcriptPath` nil omits the field.
  private func runStopHook(transcriptPath: String?) async throws -> String {
    let base: [String: String] = ["SUPACODE_SURFACE_ID": UUID().uuidString]
    let command = AgentHookSettingsCommand.claudeStopCommand(agent: .claude)
    let pathField = transcriptPath.map { #","transcript_path":"\#($0)""# } ?? ""
    let json = #"{"hook_event_name":"Stop","session_id":"S"\#(pathField)}"#
    return try await runHookCommandCapturingTTY(command, env: base, stdin: json)
  }

  /// Same, with `session_id` omitted from the hook payload.
  private func runStopHookWithoutSessionID(transcriptPath: String) async throws -> String {
    let base: [String: String] = ["SUPACODE_SURFACE_ID": UUID().uuidString]
    let command = AgentHookSettingsCommand.claudeStopCommand(agent: .claude)
    let json = #"{"hook_event_name":"Stop","transcript_path":"\#(transcriptPath)"}"#
    return try await runHookCommandCapturingTTY(command, env: base, stdin: json)
  }

  @Test func stopEmitsErrorWhenCurrentTurnEndedInError() async throws {
    let transcript = try writeTranscript([
      Self.transcriptLine(type: "user"),
      Self.transcriptLine(type: "assistant"),
      Self.transcriptLine(type: "assistant", isApiError: true),
    ])
    defer { try? FileManager.default.removeItem(at: transcript) }
    let tty = try await runStopHook(transcriptPath: transcript.path)
    #expect(tty.contains("event=error"))
    #expect(!tty.contains("event=idle"))
  }

  @Test func stopIdlesWhenErrorIsStaleAfterReprompt() async throws {
    // A later user re-prompt means the turn moved on: the error is stale.
    let transcript = try writeTranscript([
      Self.transcriptLine(type: "assistant", isApiError: true),
      Self.transcriptLine(type: "user"),
    ])
    defer { try? FileManager.default.removeItem(at: transcript) }
    let tty = try await runStopHook(transcriptPath: transcript.path)
    #expect(tty.contains("event=idle"))
    #expect(!tty.contains("event=error"))
  }

  @Test func stopIdlesWhenErrorFollowedByCleanAssistant() async throws {
    // A later non-error assistant reply means the model recovered.
    let transcript = try writeTranscript([
      Self.transcriptLine(type: "assistant", isApiError: true),
      Self.transcriptLine(type: "assistant"),
    ])
    defer { try? FileManager.default.removeItem(at: transcript) }
    let tty = try await runStopHook(transcriptPath: transcript.path)
    #expect(tty.contains("event=idle"))
    #expect(!tty.contains("event=error"))
  }

  @Test func stopIdlesWhenNoErrorPresent() async throws {
    let transcript = try writeTranscript([
      Self.transcriptLine(type: "user"),
      Self.transcriptLine(type: "assistant"),
    ])
    defer { try? FileManager.default.removeItem(at: transcript) }
    let tty = try await runStopHook(transcriptPath: transcript.path)
    #expect(tty.contains("event=idle"))
    #expect(!tty.contains("event=error"))
  }

  @Test func stopIgnoresErrorFromDifferentSession() async throws {
    // An isApiErrorMessage entry from another session must not flag this turn.
    let transcript = try writeTranscript([
      Self.transcriptLine(type: "assistant", sessionId: "OTHER", isApiError: true)
    ])
    defer { try? FileManager.default.removeItem(at: transcript) }
    let tty = try await runStopHook(transcriptPath: transcript.path)
    #expect(tty.contains("event=idle"))
    #expect(!tty.contains("event=error"))
  }

  @Test func stopIdlesWhenTranscriptMissing() async throws {
    let missing = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("supacode-missing-\(UUID().uuidString).jsonl")
    let tty = try await runStopHook(transcriptPath: missing.path)
    #expect(tty.contains("event=idle"))
    #expect(!tty.contains("event=error"))
  }

  @Test func stopIdlesWhenTranscriptPathAbsent() async throws {
    let tty = try await runStopHook(transcriptPath: nil)
    #expect(tty.contains("event=idle"))
    #expect(!tty.contains("event=error"))
  }

  @Test func stopErrorEmitsFixedNotificationThroughTheNormalPipeline() async throws {
    let transcript = try writeTranscript([
      Self.transcriptLine(type: "assistant", isApiError: true)
    ])
    defer { try? FileManager.default.removeItem(at: transcript) }
    let tty = try await runStopHook(transcriptPath: transcript.path)
    #expect(tty.contains("event=error"))
    let notify = try #require(Self.parseNotify(fromTTY: tty))
    #expect(notify.body == AgentHookSettingsCommand.errorNotifyBody)
    #expect(notify.title == AgentHookSettingsCommand.errorNotifyTitle)
  }

  @Test func stopIdlesWhenTheHookPayloadCarriesNoSessionID() async throws {
    // Without a session id the probe cannot tell whose error it is looking at, so
    // it must fall back to idle rather than flag another session's stale error.
    let transcript = try writeTranscript([
      Self.transcriptLine(type: "assistant", isApiError: true)
    ])
    defer { try? FileManager.default.removeItem(at: transcript) }
    let tty = try await runStopHookWithoutSessionID(transcriptPath: transcript.path)
    #expect(tty.contains("event=idle"))
    #expect(!tty.contains("event=error"))
  }

  @Test func stopIdleBranchStillForwardsTheTurnNotification() async throws {
    // The idle branch reuses the stdin the probe already consumed; if `$__in` stops
    // propagating, every normal turn-end notification silently loses its body.
    let transcript = try writeTranscript([Self.transcriptLine(type: "assistant")])
    defer { try? FileManager.default.removeItem(at: transcript) }
    let json =
      #"{"hook_event_name":"Stop","session_id":"S","transcript_path":"\#(transcript.path)","#
      + #""last_assistant_message":"all done"}"#
    let tty = try await runHookCommandCapturingTTY(
      AgentHookSettingsCommand.claudeStopCommand(agent: .claude),
      env: ["SUPACODE_SURFACE_ID": UUID().uuidString],
      stdin: json
    )
    #expect(tty.contains("event=idle"))
    let notify = try #require(Self.parseNotify(fromTTY: tty))
    #expect(notify.body == "all done")
  }

  // MARK: - OSC presence round-trip.

  @Test func presenceOSCRoundTripsThroughParser() async throws {
    // The shell-produced OSC must parse back into a well-formed, pid-bearing
    // signal. A guard against a template change that subtly breaks the wire.
    let surfaceID = UUID()
    let captured = try await runHookCommandCapturingTTY(
      AgentHookSettingsCommand.compositeCommand(
        events: [.sessionStart], forwardStdinAsNotification: false, agent: .claude),
      env: [
        "SUPACODE_SURFACE_ID": surfaceID.uuidString,
        "SUPACODE_SOCKET_PATH": "/tmp/supacode-rt-\(UUID().uuidString)",
      ]
    )
    let signal = try #require(Self.parsePresence(fromTTY: captured))
    #expect(signal.agent == "claude")
    #expect(signal.eventRawValue == "session_start")
    // `Process` spawns the hook shell straight from the test runner, so `$__ppid`
    // must decode to this pid. A weaker "is positive" check would pass for an emit
    // that sent the shell's own `$$`, which is the regression this pins.
    #expect(signal.pid == ProcessInfo.processInfo.processIdentifier)
  }

  @Test func presenceOmitsPidWhenParentLookupFails() async throws {
    // `ps` unreachable leaves `$__ppid` empty; the emit must then drop the pid field
    // rather than send a dangling `pid=`. In production the same `ps` failure also
    // empties `$__tty`, so this only lands when the hook has a usable controlling
    // terminal; the harness rewrites the sink, which decouples the two here.
    let emptyPath = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("supacode-nops-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: emptyPath, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: emptyPath) }

    let captured = try await runHookCommandCapturingTTY(
      AgentHookSettingsCommand.compositeCommand(
        events: [.busy], forwardStdinAsNotification: false, agent: .claude),
      env: [
        "SUPACODE_SURFACE_ID": UUID().uuidString,
        "SUPACODE_SOCKET_PATH": "/tmp/supacode-nops-\(UUID().uuidString)",
        "PATH": emptyPath.path,
      ]
    )
    #expect(!captured.contains("pid="))
    let signal = try #require(Self.parsePresence(fromTTY: captured))
    #expect(signal.eventRawValue == "busy")
    #expect(signal.pid == nil)
  }

  @Test func everyAgentCommandOnlyNamesForwardedOrLocalVariables() {
    // Grok preflights `$VAR` / `${VAR}` in a hook command as required env and skips
    // the hook when one is unset, which is how the shell special `$PPID` no-opped
    // every managed presence hook. The command shape is shared, so hold every agent
    // to the allowlist, not just Grok.
    var commands: [String] = SkillAgent.allCases.flatMap { agent in
      [
        AgentHookSettingsCommand.compositeCommand(
          events: [.sessionEnd, .idle], forwardStdinAsNotification: false, agent: agent),
        AgentHookSettingsCommand.compositeCommand(
          events: [.idle], forwardStdinAsNotification: true, agent: agent),
        AgentHookSettingsCommand.compositeCommand(
          events: [], forwardStdinAsNotification: true, agent: agent),
      ]
    }
    commands.append(AgentHookSettingsCommand.claudeStopCommand(agent: .claude))
    #expect(commands.allSatisfy { !ManagedHookCommandVariables.names(in: $0).isEmpty })
    #expect(commands.allSatisfy { ManagedHookCommandVariables.unexpected(in: $0).isEmpty })
  }

  /// Reconstructs libghostty's OSC 3008 split from a captured tty stream: the
  /// first `verb=id` field becomes the context id, the rest is the metadata
  /// `parse` consumes. Returns the parsed signal.
  private static func parsePresence(fromTTY tty: String) -> AgentPresenceOSC.Signal? {
    guard let marker = tty.range(of: "]3008;") else { return nil }
    let afterMarker = tty[marker.upperBound...]
    guard let stRange = afterMarker.range(of: "\u{1b}\\") else { return nil }
    let body = afterMarker[..<stRange.lowerBound]
    guard let firstSemi = body.firstIndex(of: ";") else { return nil }
    let firstField = body[..<firstSemi]
    let metadata = String(body[body.index(after: firstSemi)...])
    guard let equals = firstField.firstIndex(of: "=") else { return nil }
    let id = String(firstField[firstField.index(after: equals)...])
    return AgentPresenceOSC.parse(id: id, metadata: metadata)
  }

  /// Same split as `parsePresence`, but targets the notify OSC (which may follow a
  /// presence OSC in the same tty stream) by anchoring on its `kind=notify`.
  private static func parseNotify(fromTTY tty: String) -> AgentPresenceOSC.NotifySignal? {
    guard let kindRange = tty.range(of: "kind=notify") else { return nil }
    guard
      let marker = tty.range(
        of: "]3008;", options: .backwards, range: tty.startIndex..<kindRange.lowerBound)
    else { return nil }
    let afterMarker = tty[marker.upperBound...]
    guard let stRange = afterMarker.range(of: "\u{1b}\\") else { return nil }
    let body = afterMarker[..<stRange.lowerBound]
    guard let firstSemi = body.firstIndex(of: ";") else { return nil }
    let firstField = body[..<firstSemi]
    let metadata = String(body[body.index(after: firstSemi)...])
    guard let equals = firstField.firstIndex(of: "=") else { return nil }
    let id = String(firstField[firstField.index(after: equals)...])
    return AgentPresenceOSC.parseNotify(id: id, metadata: metadata)
  }

  // Shared head: surface-id guard, then (inside one brace group) resolve $__ppid /
  // $__tty from the parent agent's terminal since the hook has none of its own.
  private static let guardAndTTY =
    #"[ -n "${SUPACODE_SURFACE_ID:-}" ] && { "#
    + #"__ppid=$(ps -o ppid= -p $$ 2>/dev/null | tr -d '[:space:]'); "#
    + #"__tty=$(ps -o tty= -p "$__ppid" 2>/dev/null | tr -d '[:space:]'); "#
    + #"case "$__tty" in *[0-9]*) __tty="/dev/${__tty#/dev/}";; *) __tty="/dev/tty";; esac; "#
  private static let suppressTail = #"} >/dev/null 2>&1 || true # supacode-managed-hook"#

  private static func presence(_ action: String, _ agent: String, _ event: String) -> String {
    #"__sp=""; [ -n "${SUPACODE_SOCKET_PATH:-}" ] && [ -n "$__ppid" ] "#
      + #"&& __sp=";pid=$__ppid"; "#
      + #"printf '\033]3008;\#(action)=\#(agent);event=\#(event)%s\033\\' "$__sp" > "$__tty"; "#
  }

  private static func notify(_ agent: String) -> String {
    let bodyKeys = AgentPresenceOSC.notifyBodyKeys.joined(separator: ",")
    let awk = AgentPresenceOSC.notifyExtractAwk
    return #"__in=$(cat); "#
      + #"__t=$(printf '%s' "$__in" | LC_ALL=C awk -v keys="\#(AgentPresenceOSC.titleField)" "#
      + #"-v budget=\#(AgentPresenceOSC.notifyTitleByteBudget) '\#(awk)' | base64 | tr -d '\n'); "#
      + #"__b=$(printf '%s' "$__in" | LC_ALL=C awk -v keys="\#(bodyKeys)" "#
      + #"-v budget=\#(AgentPresenceOSC.notifyBodyByteBudget) '\#(awk)' | base64 | tr -d '\n'); "#
      + #"printf '\033]3008;start=\#(agent);kind=notify;title=%s;body=%s\033\\' "$__t" "$__b" > "$__tty"; "#
  }

  static let snapshotClaudeBusy =
    guardAndTTY + presence("start", "claude", "busy") + suppressTail

  static let snapshotClaudeIdleAndNotify =
    guardAndTTY + presence("start", "claude", "idle") + notify("claude") + suppressTail

  static let snapshotClaudeSessionEndAndIdle =
    guardAndTTY + presence("end", "claude", "session_end") + presence("start", "claude", "idle") + suppressTail

  static let snapshotCodexIdleAndNotify =
    guardAndTTY + presence("start", "codex", "idle") + notify("codex") + suppressTail

  static let snapshotKiroIdleAndNotify =
    guardAndTTY + presence("start", "kiro", "idle") + notify("kiro") + suppressTail

  static let snapshotOpencodeBusy =
    guardAndTTY + presence("start", "opencode", "busy") + suppressTail

  static let snapshotOpencodeSessionEndAndIdle =
    guardAndTTY + presence("end", "opencode", "session_end") + presence("start", "opencode", "idle") + suppressTail

  /// Runs `command` with `/dev/tty` (the OSC sink) redirected to a capture file,
  /// optionally feeding `stdin`, and returns the text written to the fake tty.
  private func runHookCommandCapturingTTY(
    _ command: String, env: [String: String], stdin: String = ""
  ) async throws -> String {
    let workDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("supacode-hook-tty-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workDir) }
    let captureFile = workDir.appendingPathComponent("tty")
    FileManager.default.createFile(atPath: captureFile.path, contents: nil)
    // Append (`>>`) not truncate: a real /dev/tty streams, so multiple OSC writes
    // (presence + notify) must both land. A plain `> file` would have the second
    // printf clobber the first.
    let patched = command.replacing(#"> "$__tty""#, with: ">> \(captureFile.path)")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    // `-f` skips the rc files, which commonly rewrite PATH and would undo a test's
    // deliberately stripped environment.
    process.arguments = ["-f", "-c", patched]
    var environment = ProcessInfo.processInfo.environment
    // The host may already export Supacode-surface vars (tests can run inside a
    // Supacode surface); clear them so every absent-variable assertion is genuine.
    environment.removeValue(forKey: "SUPACODE_SOCKET_PATH")
    environment.removeValue(forKey: "SUPACODE_SURFACE_ID")
    for (key, value) in env { environment[key] = value }
    process.environment = environment
    let stdinPipe = Pipe()
    process.standardInput = stdinPipe
    let (exited, exitContinuation) = AsyncStream<Void>.makeStream()
    process.terminationHandler = { _ in exitContinuation.finish() }
    try process.run()
    stdinPipe.fileHandleForWriting.write(Data(stdin.utf8))
    try? stdinPipe.fileHandleForWriting.close()
    for await _ in exited {}
    // Cancellation ends the iteration early; returning here would read an
    // empty capture file and let emptiness assertions pass vacuously.
    guard !Task.isCancelled else {
      if process.isRunning { process.terminate() }
      throw CancellationError()
    }
    return try String(contentsOf: captureFile, encoding: .utf8)
  }
}
