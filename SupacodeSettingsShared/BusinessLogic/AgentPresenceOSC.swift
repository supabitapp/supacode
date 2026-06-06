import Foundation

/// OSC 3008 (UAPI hierarchical context signal) wire format that carries the
/// agent-presence event lifecycle over the terminal stream, so the badge tracks
/// state over SSH where the local Unix socket can't be reached. The sequence is
/// inert in any terminal that doesn't handle OSC 3008 (no toast, no side effect).
///
/// Emit shape: `OSC 3008 ; <action>=<agent> ; event=<event> ; token=<token>[ ; pid=<pid>] ST`.
/// libghostty splits that into `id = <agent>` (the context id, up to the first
/// `;`) and `metadata = "event=<event>;token=<token>[;pid=<pid>]"`, which is what
/// `parse` receives. `parse` derives the event solely from the `event=` field and
/// ignores the start/end action byte.
/// - attribution is by the receiving surface, so no surface id is carried;
/// - `event` is the `HookEvent` rawValue;
/// - `token` echoes the per-surface `SUPACODE_OSC_TOKEN` capability nonce, which
///   the app verifies against the receiving surface before trusting the signal;
/// - `pid` is the agent's LOCAL process id, present only when the hook ran on the
///   same host (gated on `SUPACODE_SOCKET_PATH`); it feeds the app's liveness
///   sweep so a crashed local agent is reaped. Omitted over SSH.
///
/// The same transport also carries the rich notification leg
/// (`kind=notify;token=<token>;data=<base64-json>`); presence and notify are
/// disjoint metadata shapes routed by which `parse*` succeeds.
///
/// Single source of truth for both the emit side (the agent hook) and the parse
/// side (the app), so the field names can't drift.
public nonisolated enum AgentPresenceOSC {
  /// Env var carrying the per-surface secret capability nonce. Present only on
  /// Supacode surfaces, so its presence doubles as the no-op-outside-Supacode gate.
  public static let tokenEnvVar = "SUPACODE_OSC_TOKEN"

  static let eventField = "event"
  static let tokenField = "token"
  static let pidField = "pid"
  static let kindField = "kind"
  static let dataField = "data"
  static let notifyKind = "notify"

  /// A parsed, NOT-yet-trusted presence signal. The caller must verify `token`
  /// against the receiving surface's nonce before acting on it.
  public struct Signal: Equatable, Sendable {
    /// Context id, i.e. the agent rawValue.
    public let agent: String
    /// A known HookEvent rawValue. Parse rejects unknown values; stored as
    /// String so wire concerns don't leak into the enum.
    public let eventRawValue: String
    public let token: String
    /// The agent's process id, trusted via the per-surface token, not verified
    /// local: parse/trust can't distinguish a genuinely-local emit from a forged
    /// `pid=` on the wire. The emit gates it on `SUPACODE_SOCKET_PATH` so a
    /// legitimate local hook carries it and a remote one omits it, but a forged
    /// positive pid at worst pins a live-looking badge until surface close.
    public let pid: pid_t?
  }

  /// Parse the OSC 3008 context id + raw key=value metadata (as surfaced by
  /// libghostty) into a `Signal`. Returns nil for anything that isn't a
  /// well-formed presence signal with a known event. Does NOT verify the token.
  public static func parse(id: String, metadata: String) -> Signal? {
    guard !id.isEmpty else { return nil }
    guard let fields = parseFields(metadata) else { return nil }
    guard
      let rawEvent = fields[Substring(eventField)],
      HookEvent(rawValue: String(rawEvent)) != nil
    else { return nil }
    guard let token = fields[Substring(tokenField)], !token.isEmpty else { return nil }
    return Signal(
      agent: id,
      eventRawValue: String(rawEvent),
      token: String(token),
      pid: parsePid(fields[Substring(pidField)]),
    )
  }

  /// Parse the optional `pid=` field. Rejects non-numeric and non-positive
  /// values: a 0 / negative pid would let `kill(_:0)` match the caller's process
  /// group and pin a permanent badge in the liveness sweep.
  private static func parsePid(_ raw: Substring?) -> pid_t? {
    guard let raw, let value = pid_t(raw), value > 0 else { return nil }
    return value
  }

  /// True when the metadata carries `kind=notify`. Cheap routing check (presence
  /// vs notify) that inspects the `kind` field, not a raw substring, so a base64
  /// `data` value that happens to contain "kind=notify" can't misroute.
  public static func isNotifyMetadata(_ metadata: String) -> Bool {
    parseFields(metadata)?[Substring(kindField)] == Substring(notifyKind)
  }

  /// Split the OSC 3008 raw metadata into its `key=value` fields. Standard base64
  /// values are framing-safe here: their alphabet (A-Za-z0-9+/=) has no `;`, and
  /// the value keeps everything after the FIRST `=` (`firstIndex(of:)`), so base64
  /// `=` padding survives intact.
  ///
  /// Duplicate trust-bearing keys (`token`, `event`, `kind`) are rejected: a
  /// repeated key would otherwise pin perceived state to the last occurrence,
  /// which an attacker who can splice into the wire could exploit to flip
  /// `event=` or to pair a valid `token=` with an injected `kind=notify`. All
  /// other duplicate keys keep the historical last-write-wins behavior.
  static func parseFields(_ metadata: String) -> [Substring: Substring]? {
    var fields: [Substring: Substring] = [:]
    for pair in metadata.split(separator: ";", omittingEmptySubsequences: true) {
      guard let equalsIndex = pair.firstIndex(of: "=") else { continue }
      let key = pair[..<equalsIndex]
      if fields[key] != nil, Self.trustBearingFields.contains(key) {
        return nil
      }
      fields[key] = pair[pair.index(after: equalsIndex)...]
    }
    return fields
  }

  private static let trustBearingFields: Set<Substring> = [
    Substring(tokenField), Substring(eventField), Substring(kindField),
  ]

  /// A parsed, NOT-yet-trusted notification signal. `payload` is the decoded
  /// agent JSON (the same shape the socket notify pipeline forwards). The caller
  /// must verify `token` against the receiving surface's nonce before acting.
  public struct NotifySignal: Equatable, Sendable {
    /// Context id, i.e. the agent rawValue.
    public let agent: String
    public let token: String
    /// The base64-decoded agent notification JSON.
    public let payload: Data
  }

  /// Parse an OSC 3008 notify signal (`kind=notify;token=<token>;data=<base64>`).
  /// Returns nil unless it carries the notify kind, a non-empty token, and a
  /// base64-decodable payload. Does NOT verify the token.
  public static func parseNotify(id: String, metadata: String) -> NotifySignal? {
    guard !id.isEmpty else { return nil }
    guard let fields = parseFields(metadata) else { return nil }
    guard fields[Substring(kindField)] == Substring(notifyKind) else { return nil }
    guard let token = fields[Substring(tokenField)], !token.isEmpty else { return nil }
    guard
      let rawData = fields[Substring(dataField)],
      let payload = Data(base64Encoded: String(rawData))
    else { return nil }
    return NotifySignal(agent: id, token: String(token), payload: payload)
  }

  /// The OSC 3008 action for an event: session_end ends a context, everything
  /// else starts / updates one. The app keys off `event=` in the metadata, not
  /// this action, so it is descriptive rather than load-bearing.
  static func action(for event: HookEvent) -> String {
    event == .sessionEnd ? "end" : "start"
  }

  /// The `key=value` metadata a PRESENCE signal carries (everything after the
  /// context id). `parse` recovers the event from this exact shape. `pidSuffix`
  /// is appended verbatim (e.g. `;pid=123`) so the emit can splice in a
  /// shell-built, conditionally-empty suffix. See `notifyMetadata` for the
  /// notify counterpart.
  static func metadata(event: HookEvent, token: String, pidSuffix: String = "") -> String {
    "\(eventField)=\(event.rawValue);\(tokenField)=\(token)\(pidSuffix)"
  }

  /// Shell that resolves `$__tty` to a writable terminal device for the OSC emits.
  /// Agents run hooks without a controlling terminal (`/dev/tty` open fails), so
  /// the hook recovers the terminal its parent agent is attached to via
  /// `ps -o tty=`. `ps` reports a bare name (`ttys039` on macOS, `pts/5` on
  /// Linux), so a `/dev/` prefix is added; a parent with no tty (`??`) falls back
  /// to `/dev/tty` for the rare context that does have a controlling terminal.
  static let ttyResolveSnippet =
    #"__tty=$(ps -o tty= -p "$PPID" 2>/dev/null | tr -d '[:space:]'); "#
    + #"case "$__tty" in *[0-9]*) __tty="/dev/${__tty#/dev/}";; *) __tty="/dev/tty";; esac"#

  /// Shell `printf` that emits the OSC 3008 presence sequence for `event`,
  /// echoing `$SUPACODE_OSC_TOKEN` for the token placeholder. Written to the
  /// `$__tty` device resolved by `ttyResolveSnippet` so it reaches the terminal
  /// even though the hook has no controlling terminal and captured stdout. The
  /// caller guards emission on the token env var and runs `ttyResolveSnippet`
  /// first.
  ///
  /// The pid suffix is gated on `SUPACODE_SOCKET_PATH` (set only on the local
  /// host) so a legitimate local hook carries `$PPID` and a remote one omits it.
  /// This is not verified on receipt: the per-surface token is the only real
  /// gate, and a forged positive pid at worst pins a live-looking badge until
  /// surface close. The suffix is built in shell and filled into a trailing
  /// `%s`, empty when remote.
  static func emitShell(event: HookEvent, agent: SkillAgent) -> String {
    // token=%s then a trailing %s for the shell-built, conditionally-empty pid suffix.
    let meta = metadata(event: event, token: "%s", pidSuffix: "%s")
    let payload = #"\033]3008;\#(action(for: event))=\#(agent.rawValue);\#(meta)\033\\"#
    return #"__sp=""; [ -n "${SUPACODE_SOCKET_PATH:-}" ] && __sp=";\#(pidField)=$PPID"; "#
      + #"printf '\#(payload)' "$\#(tokenEnvVar)" "$__sp" > "$__tty""#
  }

  /// The `key=value` metadata a notify signal carries. `parseNotify` recovers the
  /// payload from this exact shape.
  static func notifyMetadata(token: String, data: String) -> String {
    "\(kindField)=\(notifyKind);\(tokenField)=\(token);\(dataField)=\(data)"
  }

  /// Shell snippet that reads the agent notification JSON from stdin,
  /// base64-encodes it, and emits the OSC 3008 notify sequence echoing
  /// `$SUPACODE_OSC_TOKEN`. `base64 | tr -d '\n'` is portable (macOS + Linux) and
  /// strips the wrapping newlines so the payload stays a single OSC field. The
  /// emit/parse pair is locked to STANDARD base64 (`Data(base64Encoded:)` rejects
  /// the URL-safe alphabet a busybox/alpine `base64` might default to).
  static func emitNotifyShell(agent: SkillAgent) -> String {
    let payload = #"\033]3008;start=\#(agent.rawValue);\#(notifyMetadata(token: "%s", data: "%s"))\033\\"#
    return #"__osc_d=$(base64 | tr -d '\n'); printf '\#(payload)' "$\#(tokenEnvVar)" "$__osc_d" > "$__tty""#
  }

  /// Equal-length constant-time compare. A length mismatch returns immediately;
  /// safe because the expected token is server-generated and fixed-length
  /// (32 hex chars), not attacker-controlled.
  public static func tokensMatch(_ lhs: String, _ rhs: String) -> Bool {
    let lhsBytes = Array(lhs.utf8)
    let rhsBytes = Array(rhs.utf8)
    guard lhsBytes.count == rhsBytes.count else { return false }
    var diff: UInt8 = 0
    for index in lhsBytes.indices { diff |= lhsBytes[index] ^ rhsBytes[index] }
    return diff == 0
  }
}
