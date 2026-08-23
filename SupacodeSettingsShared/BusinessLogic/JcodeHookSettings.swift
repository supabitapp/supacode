import Foundation

/// Canonical jcode hook definition: the Supacode-managed entries in jcode's
/// `[hooks]` table (`~/.jcode/config.toml`), plus the body of the presence-hook
/// wrapper they point at (`~/.jcode/hooks/supacode-presence.sh`).
///
/// jcode differs from Kimi in one way that shapes this whole module: jcode
/// executes a hook command directly — the line is only split shell-style, never
/// run through a shell — so Supacode's presence one-liner, which needs `printf` /
/// `ps` / `case` / `&&`, cannot be inlined into the TOML the way `KimiHookSettings`
/// does. Instead each `[hooks]` entry points at an executable wrapper the
/// installer writes, and the wrapper carries the presence logic. The wrapper is
/// composed from the shared `AgentPresenceOSC` snippets, so the `OSC 3008`
/// presence signal it emits is byte-identical to every other harness and the
/// parse side cannot drift.
nonisolated enum JcodeHookSettings {
  /// The lifecycle events Supacode hooks: session_start / turn_start / turn_end /
  /// session_end. `pre_tool` / `post_tool` are left to the user (a `pre_tool`
  /// hook is a blocking gate, not a presence signal). Each maps to an
  /// `AgentPresenceOSC` event inside the wrapper's dispatch:
  /// `session_start`→sessionStart, `turn_start`→busy, `turn_end`→idle/error,
  /// `session_end`→sessionEnd+idle.
  static let hookedEvents = ["session_start", "turn_start", "turn_end", "session_end"]

  /// Path components of the wrapper under the jcode config directory (`~/.jcode`).
  static let wrapperDirectoryName = "hooks"
  static let wrapperFileName = "supacode-presence.sh"

  /// Absolute URL of the wrapper for a given home directory:
  /// `~/.jcode/hooks/supacode-presence.sh`.
  static func wrapperURL(homeDirectoryURL: URL) -> URL {
    homeDirectoryURL
      .appending(path: SkillAgent.jcode.configDirectoryName, directoryHint: .isDirectory)
      .appending(path: wrapperDirectoryName, directoryHint: .isDirectory)
      .appending(path: wrapperFileName, directoryHint: .notDirectory)
  }

  /// The presence-hook wrapper's body. It begins with `#!/bin/sh` — jcode runs
  /// the hook with no shell, so the wrapper must supply its own — carries the
  /// ownership marker, and is inert outside a Supacode surface (the
  /// `SUPACODE_SURFACE_ID` guard). It resolves the pane tty and dispatches on
  /// `$JCODE_HOOK_EVENT`, reusing `AgentPresenceOSC` verbatim so the wire format
  /// matches every other harness.
  ///
  /// Note: the per-pane session binding (`session=$JCODE_HOOK_SESSION_ID`) is
  /// intentionally omitted until `AgentPresenceOSC` carries a matching `session`
  /// field; add it to this wrapper in the same change so the field only appears
  /// once a consumer can read it.
  static func wrapperScript() -> String {
    let tty = AgentPresenceOSC.ttyResolveSnippet
    let sessionStart = AgentPresenceOSC.emitShell(event: .sessionStart, agent: .jcode)
    let busy = AgentPresenceOSC.emitShell(event: .busy, agent: .jcode)
    let idle = AgentPresenceOSC.emitShell(event: .idle, agent: .jcode)
    let error = AgentPresenceOSC.emitShell(event: .error, agent: .jcode)
    let sessionEnd = AgentPresenceOSC.emitShell(event: .sessionEnd, agent: .jcode)
    let errorNotify = AgentPresenceOSC.emitFixedNotifyShell(
      agent: .jcode,
      title: AgentHookSettingsCommand.errorNotifyTitle,
      body: AgentHookSettingsCommand.errorNotifyBody,
    )
    return """
      #!/bin/sh
      \(AgentHookSettingsCommand.ownershipMarker)
      # Managed by Supacode: emits OSC 3008 agent-presence for jcode panes. jcode
      # exec's hooks directly (no shell), so this wrapper carries the presence
      # snippet the other harnesses inline. Safe to delete — Supacode reinstalls it.
      # Do not edit by hand; changes are overwritten on the next install.
      [ -n "${SUPACODE_SURFACE_ID:-}" ] || exit 0
      \(tty)
      case "${JCODE_HOOK_EVENT:-}" in
      session_start) \(sessionStart) ;;
      turn_start) \(busy) ;;
      turn_end)
        if [ "${JCODE_HOOK_STATUS:-}" = error ]; then
          \(error); \(errorNotify)
        else
          \(idle)
        fi
        ;;
      session_end) \(sessionEnd); \(idle) ;;
      esac
      exit 0
      """
  }
}
