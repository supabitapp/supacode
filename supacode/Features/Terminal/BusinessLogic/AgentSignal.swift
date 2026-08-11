import Foundation
import SupacodeSettingsShared

/// Pure parsing, sanitizing, and timing decisions for agent-originated OSC
/// signals (presence, context, notify), shared by the live surface pipeline
/// and the dormant-session watchers.
nonisolated enum AgentSignal {
  /// How long after a custom notification the agent's own OSC 9 is suppressed.
  /// Split from `oscHoldWindow` so tuning the suppression side cannot silently
  /// change the hold side.
  static let oscSuppressionAfterCustom: TimeInterval = 0.5
  /// How long the agent's own OSC 9 is held before firing, waiting for a custom
  /// notification to supersede it. Covers the socket-vs-inline-stream arrival skew.
  static let oscHoldWindow: TimeInterval = 0.5

  /// Monotonic gap between two instants from the same clock. Opens the existentials
  /// so the suppression window can compare instants of the type-erased clock.
  static func elapsed(
    from start: any InstantProtocol<Duration>,
    to end: any InstantProtocol<Duration>
  ) -> Duration {
    func gap<I: InstantProtocol>(_ start: I, _ end: any InstantProtocol<Duration>) -> Duration
    where I.Duration == Duration {
      guard let end = end as? I else {
        // Fail OPEN: a type mismatch must not pin the dedupe window true forever.
        assertionFailure("clock instant type mismatch")
        return .seconds(Self.oscSuppressionAfterCustom + 1)
      }
      return start.duration(to: end)
    }
    return gap(start, end)
  }

  enum PresenceDrop: Error, Equatable {
    case unknownSurface
    case parseFailed
  }

  /// Pure decision for an OSC presence signal: returns an `AgentHookEvent`
  /// attributed to the RECEIVING surface when the surface is known and the metadata
  /// is well-formed; otherwise a typed `PresenceDrop` so the caller can log per
  /// cause. The wire never carries a surface id (so a payload can't spoof another
  /// worktree). The parser rejects a non-positive pid before it could reach the
  /// liveness sweep; a forged positive pid at worst pins a live-looking badge.
  static func presenceEvent(
    id: String,
    metadata: String,
    surfaceID: UUID,
    surfaceExists: Bool
  ) -> Result<AgentHookEvent, PresenceDrop> {
    guard surfaceExists else { return .failure(.unknownSurface) }
    guard let signal = AgentPresenceOSC.parse(id: id, metadata: metadata) else {
      return .failure(.parseFailed)
    }
    return .success(
      AgentHookEvent(
        agent: signal.agent, event: signal.eventRawValue, surfaceID: surfaceID, pid: signal.pid))
  }

  /// Splits a raw OSC 3008 payload (`<action>=<id>[;<metadata>]`) into context id
  /// and raw metadata, mirroring libghostty's context-signal parser for the
  /// dormant channel that bypasses it. Returns nil without a `start=` / `end=`
  /// prefix or a spec-valid id (1-64 printable ASCII bytes).
  static func contextSignalFields(payload: String) -> (id: String, metadata: String)? {
    let rest: Substring
    if payload.hasPrefix("start=") {
      rest = payload.dropFirst("start=".count)
    } else if payload.hasPrefix("end=") {
      rest = payload.dropFirst("end=".count)
    } else {
      return nil
    }
    guard !rest.isEmpty else { return nil }
    let idEnd = rest.firstIndex(of: ";") ?? rest.endIndex
    let id = rest[..<idEnd]
    guard (1...64).contains(id.count),
      id.unicodeScalars.allSatisfy({ (0x20...0x7e).contains($0.value) })
    else { return nil }
    let metadata = idEnd < rest.endIndex ? rest[rest.index(after: idEnd)...] : ""
    return (String(id), String(metadata))
  }

  /// Typed reasons a notify signal was dropped, so the single call site can pick a
  /// log severity per cause (warn for malformed, debug otherwise).
  enum NotifyDrop: Error {
    case unknownSurface
    case parseFailed
    case empty
  }

  /// A parsed + sanitized notify ready for display, plus the raw wire body byte
  /// count so the call site can log a truncated-to-empty body.
  struct ResolvedNotification: Equatable {
    let title: String
    let body: String
    let wireBodyByteCount: Int
  }

  /// Pure parse decision for an OSC notify signal. Title/body are bounded and
  /// stripped of control characters since anything on the terminal can emit one.
  /// Title falls back to the agent name; body may be empty.
  static func notification(
    id: String,
    metadata: String,
    surfaceExists: Bool
  ) -> Result<ResolvedNotification, NotifyDrop> {
    guard surfaceExists else { return .failure(.unknownSurface) }
    guard let notify = AgentPresenceOSC.parseNotify(id: id, metadata: metadata) else {
      return .failure(.parseFailed)
    }
    // Second-line defense behind the emit-side caps (notifyTitleByteBudget /
    // notifyBodyByteBudget): these are scalar counts, not bytes, and the wire is
    // already bounded, so they only bite on a hand-crafted oversized payload.
    let title = sanitizeNotificationText(notify.title ?? notify.agent, max: 200)
    let body = sanitizeNotificationText(notify.body ?? "", max: 1000)
    guard !(title.isEmpty && body.isEmpty) else { return .failure(.empty) }
    return .success(ResolvedNotification(title: title, body: body, wireBodyByteCount: notify.wireBodyByteCount))
  }

  /// Bound length and neutralize control characters in attacker-influenceable
  /// notification text. Newline / tab / carriage return collapse to a space;
  /// other C0 controls and DEL are dropped (defends against escape-sequence
  /// injection into the toast). Length is capped in unicode scalars.
  static func sanitizeNotificationText(_ text: String, max: Int) -> String {
    var scalars = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
      if scalars.count >= max { break }
      switch scalar.value {
      case 0x0A, 0x09, 0x0D:
        scalars.append(" ")
      case 0x00...0x1F, 0x7F:
        continue
      default:
        scalars.append(scalar)
      }
    }
    return String(scalars).trimmingCharacters(in: .whitespaces)
  }

  /// True when an OSC 9 payload is a ConEmu subcommand (its first `;`-separated
  /// field is an integer 1...12), not an iTerm2 notification body. Mirrors
  /// libghostty's OSC-9 ConEmu-vs-notification split.
  static func isConEmuOSC9Payload(_ payload: String) -> Bool {
    guard let subcommand = Int(payload.prefix { $0 != ";" }) else { return false }
    return (1...12).contains(subcommand)
  }
}
