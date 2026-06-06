import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

struct AgentPresenceOSCTests {
  // MARK: - parse.

  @Test func parsesValidSignal() {
    let signal = AgentPresenceOSC.parse(id: "claude", metadata: "event=busy;token=abc123")
    #expect(signal?.agent == "claude")
    #expect(signal?.eventRawValue == "busy")
    #expect(signal?.token == "abc123")
  }

  @Test func rejectsEmptyId() {
    #expect(AgentPresenceOSC.parse(id: "", metadata: "event=busy;token=abc") == nil)
  }

  @Test func rejectsMissingEvent() {
    #expect(AgentPresenceOSC.parse(id: "claude", metadata: "token=abc") == nil)
  }

  @Test func rejectsUnknownEvent() {
    #expect(AgentPresenceOSC.parse(id: "claude", metadata: "event=not_a_real_event;token=abc") == nil)
  }

  @Test func rejectsMissingToken() {
    #expect(AgentPresenceOSC.parse(id: "claude", metadata: "event=busy") == nil)
  }

  @Test func rejectsEmptyToken() {
    #expect(AgentPresenceOSC.parse(id: "claude", metadata: "event=busy;token=") == nil)
  }

  @Test func ignoresUnknownFieldsAndOrdering() {
    let signal = AgentPresenceOSC.parse(id: "codex", metadata: "extra=1;token=zzz;event=session_start")
    #expect(signal?.eventRawValue == "session_start")
    #expect(signal?.token == "zzz")
    #expect(signal?.agent == "codex")
  }

  @Test func skipsBareSegmentWithoutEquals() {
    // A segment with no '=' (a stray sentinel byte) is skipped, not fatal.
    let signal = AgentPresenceOSC.parse(id: "claude", metadata: "garbage;event=idle;token=t")
    #expect(signal?.eventRawValue == "idle")
  }

  // MARK: - emit / parse round-trip.

  @Test func emitMetadataRoundTripsThroughParse() {
    for event in [HookEvent.sessionStart, .sessionEnd, .busy, .awaitingInput, .idle] {
      let metadata = AgentPresenceOSC.metadata(event: event, token: "tok123")
      let signal = AgentPresenceOSC.parse(id: "claude", metadata: metadata)
      #expect(signal?.eventRawValue == event.rawValue)
      #expect(signal?.token == "tok123")
    }
  }

  // MARK: - pid field (local-host liveness).

  @Test func parsesPositivePidField() {
    let signal = AgentPresenceOSC.parse(id: "claude", metadata: "event=busy;token=tok;pid=4321")
    #expect(signal?.pid == 4321)
  }

  @Test func absentPidParsesAsNil() {
    let signal = AgentPresenceOSC.parse(id: "claude", metadata: "event=busy;token=tok")
    #expect(signal?.eventRawValue == "busy")
    #expect(signal?.pid == nil)
  }

  @Test func rejectsNonPositiveAndGarbagePid() {
    // 0 / negatives would let `kill(_:0)` match the caller's process group and
    // pin a permanent badge; a non-numeric pid is dropped, not fatal.
    for raw in ["0", "-7", "abc", ""] {
      let signal = AgentPresenceOSC.parse(id: "claude", metadata: "event=busy;token=tok;pid=\(raw)")
      #expect(signal?.eventRawValue == "busy")
      #expect(signal?.pid == nil)
    }
  }

  @Test func rejectsPidThatOverflowsPidT() {
    // Defense in depth against a future change from `pid_t(raw)` to `Int(raw)`:
    // a value beyond pid_t's range must drop, not wrap.
    let signal = AgentPresenceOSC.parse(id: "claude", metadata: "event=busy;token=t;pid=99999999999999")
    #expect(signal?.pid == nil)
  }

  @Test func metadataPidSuffixRoundTripsThroughParse() {
    let metadata = AgentPresenceOSC.metadata(event: .busy, token: "tok", pidSuffix: ";pid=99")
    let signal = AgentPresenceOSC.parse(id: "claude", metadata: metadata)
    #expect(signal?.pid == 99)
  }

  @Test func presenceEventThreadsLocalPid() {
    let metadata = AgentPresenceOSC.metadata(event: .busy, token: "tok", pidSuffix: ";pid=4242")
    let result = WorktreeTerminalState.presenceEvent(
      id: "claude", metadata: metadata, expectedToken: "tok", surfaceID: UUID(), surfaceExists: true)
    #expect((try? result.get())?.pid == 4242)
  }

  @Test func actionMapsSessionEndToEndElseStart() {
    #expect(AgentPresenceOSC.action(for: .sessionEnd) == "end")
    for event in [HookEvent.sessionStart, .busy, .awaitingInput, .idle] {
      #expect(AgentPresenceOSC.action(for: event) == "start")
    }
  }

  // MARK: - tokensMatch (anti-spoof compare).

  @Test func tokensMatchEqual() {
    #expect(AgentPresenceOSC.tokensMatch("abc123", "abc123"))
  }

  @Test func tokensMatchEmpty() {
    #expect(AgentPresenceOSC.tokensMatch("", ""))
  }

  @Test func tokensMatchRejectsOneByteDifference() {
    #expect(!AgentPresenceOSC.tokensMatch("abc123", "abc124"))
  }

  @Test func tokensMatchRejectsDifferentLengths() {
    #expect(!AgentPresenceOSC.tokensMatch("abc", "abc1"))
  }

  // MARK: - makeOSCToken (fixed-length hex invariant).

  @MainActor
  @Test func makeOSCTokenAlwaysReturns32LowercaseHexChars() {
    // Guards `tokensMatch`'s fixed-length contract against regressions on either
    // the SecRandomCopyBytes path or the arc4random_buf fallback.
    let allowed = Set("0123456789abcdef")
    for _ in 0..<100 {
      let token = WorktreeTerminalState.makeOSCToken()
      #expect(token.count == 32)
      #expect(token.allSatisfy { allowed.contains($0) })
    }
  }

  // MARK: - presenceEvent (trust boundary + attribution).

  @Test func presenceEventTrustsMatchingTokenAndAttributesToReceivingSurface() {
    let surfaceID = UUID()
    let metadata = AgentPresenceOSC.metadata(event: .busy, token: "tok")
    let result = WorktreeTerminalState.presenceEvent(
      id: "claude", metadata: metadata, expectedToken: "tok", surfaceID: surfaceID, surfaceExists: true)
    let event = try? result.get()
    #expect(event?.surfaceID == surfaceID)
    #expect(event?.agent == "claude")
    #expect(event?.event == "busy")
    #expect(event?.pid == nil)
  }

  @Test func presenceEventDropsMismatchedToken() {
    let metadata = AgentPresenceOSC.metadata(event: .busy, token: "wrong")
    let result = WorktreeTerminalState.presenceEvent(
      id: "claude", metadata: metadata, expectedToken: "right", surfaceID: UUID(), surfaceExists: true)
    guard case .failure(.tokenMismatch(let agent, let event)) = result else {
      Issue.record("expected tokenMismatch, got \(result)")
      return
    }
    #expect(agent == "claude")
    #expect(event == "busy")
  }

  @Test func presenceEventDropsUnknownSurface() {
    let metadata = AgentPresenceOSC.metadata(event: .busy, token: "tok")
    let result = WorktreeTerminalState.presenceEvent(
      id: "claude", metadata: metadata, expectedToken: nil, surfaceID: UUID(), surfaceExists: false)
    #expect(result == .failure(.unknownSurface))
  }

  // MARK: - AgentHookEvent synthesis.

  @Test func synthesizedHookEventDefaultsToPidlessAndKeepsSurface() {
    let surfaceID = UUID()
    let event = AgentHookEvent(agent: "claude", event: "busy", surfaceID: surfaceID)
    #expect(event.pid == nil)
    #expect(event.surfaceID == surfaceID)
    #expect(event.agent == "claude")
    #expect(event.event == "busy")
    #expect(event.version == 1)
  }

  // MARK: - parseNotify.

  @Test func parsesValidNotify() {
    let json = #"{"hook_event_name":"Stop","message":"hi"}"#
    let b64 = Data(json.utf8).base64EncodedString()
    let signal = AgentPresenceOSC.parseNotify(id: "claude", metadata: "kind=notify;token=tok;data=\(b64)")
    #expect(signal?.agent == "claude")
    #expect(signal?.token == "tok")
    #expect(signal?.payload == Data(json.utf8))
  }

  @Test func rejectsNotifyWithoutKind() {
    let b64 = Data("x".utf8).base64EncodedString()
    #expect(AgentPresenceOSC.parseNotify(id: "claude", metadata: "token=tok;data=\(b64)") == nil)
  }

  @Test func rejectsNotifyWithoutToken() {
    let b64 = Data("x".utf8).base64EncodedString()
    #expect(AgentPresenceOSC.parseNotify(id: "claude", metadata: "kind=notify;data=\(b64)") == nil)
  }

  @Test func rejectsNotifyWithoutData() {
    #expect(AgentPresenceOSC.parseNotify(id: "claude", metadata: "kind=notify;token=tok") == nil)
  }

  @Test func rejectsNotifyWithInvalidBase64() {
    #expect(AgentPresenceOSC.parseNotify(id: "claude", metadata: "kind=notify;token=tok;data=!!notb64") == nil)
  }

  @Test func rejectsNotifyWithEmptyId() {
    let b64 = Data("x".utf8).base64EncodedString()
    #expect(AgentPresenceOSC.parseNotify(id: "", metadata: "kind=notify;token=tok;data=\(b64)") == nil)
  }

  @Test func notifyMetadataRoundTripsThroughParseNotify() {
    let json = #"{"message":"round trip"}"#
    let metadata = AgentPresenceOSC.notifyMetadata(token: "tok", data: Data(json.utf8).base64EncodedString())
    let signal = AgentPresenceOSC.parseNotify(id: "codex", metadata: metadata)
    #expect(signal?.payload == Data(json.utf8))
    #expect(signal?.token == "tok")
  }

  @Test func presenceParseRejectsNotifyMetadata() {
    // Presence and notify are disjoint: a notify payload must not parse as presence.
    let b64 = Data("x".utf8).base64EncodedString()
    #expect(AgentPresenceOSC.parse(id: "claude", metadata: "kind=notify;token=tok;data=\(b64)") == nil)
  }

  // MARK: - notification (trust + sanitize).

  @Test func notificationTrustsMatchingTokenAndExtractsBody() {
    let json = #"{"hook_event_name":"Stop","message":"all done"}"#
    let metadata = "kind=notify;token=tok;data=\(Data(json.utf8).base64EncodedString())"
    let resolved = WorktreeTerminalState.notification(
      id: "claude", metadata: metadata, expectedToken: "tok", surfaceExists: true)
    guard case .success(let value) = resolved else {
      Issue.record("expected success, got \(resolved)")
      return
    }
    #expect(value.body == "all done")
  }

  @Test func notificationDropsMismatchedToken() {
    let metadata = "kind=notify;token=wrong;data=\(Data(#"{"message":"x"}"#.utf8).base64EncodedString())"
    let result = WorktreeTerminalState.notification(
      id: "claude", metadata: metadata, expectedToken: "right", surfaceExists: true)
    guard case .failure(.tokenMismatch(let agent)) = result else {
      Issue.record("expected tokenMismatch, got \(result)")
      return
    }
    #expect(agent == "claude")
  }

  @Test func notificationDropsUnknownSurface() {
    let metadata = "kind=notify;token=tok;data=\(Data(#"{"message":"x"}"#.utf8).base64EncodedString())"
    let result = WorktreeTerminalState.notification(
      id: "claude", metadata: metadata, expectedToken: nil, surfaceExists: false)
    if case .failure(.unknownSurface) = result {} else { Issue.record("expected unknownSurface, got \(result)") }
  }

  @Test func notificationDropsClosedSurfaceWithNilExpectedTokenWithoutWarning() {
    // A signal targeting a closed surface (no expected token, surface gone) is
    // benign, not a spoof: the call site routes `.unknownSurface` to `.debug`,
    // never `.warning`. Asserting the exact failure case locks that mapping in
    // since `tokenMismatch` / `parseFailed` are the only warn-level branches.
    let metadata = "kind=notify;token=tok;data=\(Data(#"{"message":"x"}"#.utf8).base64EncodedString())"
    let result = WorktreeTerminalState.notification(
      id: "claude", metadata: metadata, expectedToken: nil, surfaceExists: false)
    guard case .failure(let drop) = result else {
      Issue.record("expected failure, got \(result)")
      return
    }
    if case .unknownSurface = drop {
    } else {
      Issue.record("expected unknownSurface, got \(drop)")
    }
    if case .tokenMismatch = drop { Issue.record("unknown surface must not log as a spoof warning") }
    if case .parseFailed = drop { Issue.record("unknown surface must not log as a malformed warning") }
  }

  @Test func notificationFallsBackToAgentTitleWhenAbsent() {
    let metadata = "kind=notify;token=tok;data=\(Data(#"{"message":"body only"}"#.utf8).base64EncodedString())"
    let resolved = WorktreeTerminalState.notification(
      id: "codex", metadata: metadata, expectedToken: "tok", surfaceExists: true)
    guard case .success(let value) = resolved else {
      Issue.record("expected success, got \(resolved)")
      return
    }
    #expect(value.title == "codex")
  }

  @Test func notificationDropsPayloadThatSanitizesEmpty() {
    // Body of only control / whitespace and no usable title sanitizes to empty,
    // so the toast is suppressed rather than shown blank.
    let metadata = "kind=notify;token=tok;data=\(Data(#"{"message":"\n"}"#.utf8).base64EncodedString())"
    let result = WorktreeTerminalState.notification(
      id: " ", metadata: metadata, expectedToken: "tok", surfaceExists: true)
    if case .failure(.empty) = result {} else { Issue.record("expected empty, got \(result)") }
  }

  @Test func sanitizeStripsControlCharsAndCollapsesNewlines() {
    let dirty = "a\u{1B}[31mred\u{07}\nline"
    #expect(WorktreeTerminalState.sanitizeNotificationText(dirty, max: 1000) == "a[31mred line")
  }

  @Test func sanitizeCapsToMaxScalars() {
    let long = String(repeating: "x", count: 500)
    #expect(WorktreeTerminalState.sanitizeNotificationText(long, max: 100).count == 100)
  }

  @Test func notificationStripsEmbeddedOSCSequenceFromBody() {
    // A notify body that smuggles a nested OSC 3008 presence sequence must not
    // forward the ESC or the framing bytes to the toast: the C0 strip is the
    // only line of defense between an attacker-controlled message and the
    // terminal's own escape parser. The ESC bytes ride in via JSON's six-char
    // unicode escape (raw 0x1B is illegal in a JSON string); the C0 strip
    // must drop both the opening ESC and the trailing ST ESC before the
    // toast sees them.
    let json =
      #"{"hook_event_name":"Stop","message":"before\u001b]3008;start=evil;event=busy;token=X\u001b\\after"}"#
    let metadata = "kind=notify;token=tok;data=\(Data(json.utf8).base64EncodedString())"
    let resolved = WorktreeTerminalState.notification(
      id: "claude", metadata: metadata, expectedToken: "tok", surfaceExists: true)
    guard case .success(let value) = resolved else {
      Issue.record("expected success, got \(resolved)")
      return
    }
    // No ESC byte may reach the toast, no matter where it sat in the payload.
    #expect(!value.body.unicodeScalars.contains { $0.value == 0x1B })
    // Printable framing bytes survive (they are not C0); the load-bearing
    // assertion is that the ESC is gone, so a downstream renderer cannot
    // re-trigger an escape parser.
    #expect(value.body == #"before]3008;start=evil;event=busy;token=X\after"#)
    // The standalone sanitize entry point pins the same contract directly.
    let dirty = "before\u{1B}]3008;start=evil;event=busy;token=X\u{1B}\\after"
    #expect(
      WorktreeTerminalState.sanitizeNotificationText(dirty, max: 1000)
        == #"before]3008;start=evil;event=busy;token=X\after"#)
  }

  // MARK: - large payload (metadata cap headroom).

  @Test func largeNotifyPayloadNearMetadataCapRoundTripsEndToEnd() {
    // Locks the design margin against a future Ghostty cap reduction or a Claude
    // payload growth that would silently drop notifications: a ~1.5KB Codex
    // `last_assistant_message` must survive parseNotify + notification(...) with
    // the title / body resolving correctly. Sized so the base64-expanded
    // metadata stays just under the 2047-byte OSC cap.
    let bodyText = String(repeating: "y", count: 1400)
    let json = #"{"hook_event_name":"Stop","title":"Big","last_assistant_message":"\#(bodyText)"}"#
    let metadata = AgentPresenceOSC.notifyMetadata(
      token: "tok", data: Data(json.utf8).base64EncodedString())
    // Stay under Ghostty's 2047-byte metadata cap so a real terminal would not truncate.
    #expect(metadata.utf8.count < 2047)

    let signal = AgentPresenceOSC.parseNotify(id: "codex", metadata: metadata)
    #expect(signal?.payload == Data(json.utf8))

    let resolved = WorktreeTerminalState.notification(
      id: "codex", metadata: metadata, expectedToken: "tok", surfaceExists: true)
    guard case .success(let value) = resolved else {
      Issue.record("expected success, got \(resolved)")
      return
    }
    #expect(value.title == "Big")
    // Body is sanitized + capped at 1000 scalars (see WorktreeTerminalState.notification).
    #expect(value.body.count == 1000)
    #expect(value.body.allSatisfy { $0 == "y" })
  }
}
