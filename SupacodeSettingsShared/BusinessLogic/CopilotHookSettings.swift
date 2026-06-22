import Foundation

/// Builds `~/.copilot/hooks/supacode.json`. Copilot auto-loads every JSON file
/// there, so Supacode owns its own file (like Pi/OpenCode) and emits the shared
/// OSC 3008 presence signals from per-event `bash` hooks.
nonisolated enum CopilotHookSettings {
  static let fileName = "supacode.json"

  /// Sentinel marking the file as Supacode-managed; install/uninstall key off it.
  static let ownershipMarker = AgentHookSettingsCommand.ownershipMarker

  /// Deterministic, so `installState` can detect drift by a byte-for-byte compare.
  /// Throws rather than returning a sentinel: an empty string would be written as a
  /// valid-looking but marker-less file the installer could no longer recognize.
  static func source() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(Payload())
    guard let string = String(data: data, encoding: .utf8) else {
      throw CopilotHooksInstallerError.encodingFailed
    }
    return string
  }

  private static func command(for events: [HookEvent], notify: Bool = false) -> String {
    AgentHookSettingsCommand.compositeCommand(
      events: events, forwardStdinAsNotification: notify, agent: .copilot)
  }

  /// Branches on the payload (so it hand-composes the OSC pieces rather than using
  /// `compositeCommand`): permission / elicitation prompts flip to awaitingInput +
  /// alert; other notification types no-op since `agentStop` owns the done-alert.
  private static var notificationCommand: String {
    let surfaceGuard = #"[ -n "${\#(AgentPresenceOSC.surfaceEnvVar):-}" ]"#
    let needsYou =
      #"\#(AgentPresenceOSC.ttyResolveSnippet); "#
      + AgentPresenceOSC.emitShell(event: .awaitingInput, agent: .copilot) + "; "
      + AgentPresenceOSC.emitNotifyShell(agent: .copilot, readsStdin: false)
    let steps =
      #"__in=$(cat); case "$__in" in *permission_prompt*|*elicitation_dialog*) \#(needsYou) ;; esac"#
    return #"\#(surfaceGuard) && { \#(steps); } >/dev/null 2>&1 || true \#(ownershipMarker)"#
  }

  private struct Payload: Encodable {
    let version = 1
    let hooks: [String: [Hook]] = [
      "sessionStart": [Hook(bash: CopilotHookSettings.command(for: [.sessionStart]), timeoutSec: 5)],
      "userPromptSubmitted": [Hook(bash: CopilotHookSettings.command(for: [.busy]), timeoutSec: 10)],
      "preToolUse": [Hook(bash: CopilotHookSettings.command(for: [.busy]), timeoutSec: 5)],
      "postToolUse": [Hook(bash: CopilotHookSettings.command(for: [.busy]), timeoutSec: 5)],
      "agentStop": [Hook(bash: CopilotHookSettings.command(for: [.idle], notify: true), timeoutSec: 10)],
      "sessionEnd": [Hook(bash: CopilotHookSettings.command(for: [.sessionEnd]), timeoutSec: 5)],
      "notification": [Hook(bash: CopilotHookSettings.notificationCommand, timeoutSec: 10)],
    ]
  }

  private struct Hook: Encodable {
    let type = "command"
    let bash: String
    let timeoutSec: Int
  }
}
