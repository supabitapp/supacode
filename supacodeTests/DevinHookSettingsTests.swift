import Foundation
import Testing

@testable import SupacodeSettingsShared

struct DevinHookSettingsTests {
  @Test func hooksByEventCoverCoreEvents() throws {
    let groups = try DevinHookSettings.hooksByEvent()
    #expect(groups["SessionStart"] != nil)
    #expect(groups["UserPromptSubmit"] != nil)
    #expect(groups["PreToolUse"] != nil)
    #expect(groups["PermissionRequest"] != nil)
    #expect(groups["PostToolUse"] != nil)
    #expect(groups["Stop"] != nil)
    #expect(groups["SessionEnd"] != nil)
    // Devin has no Notification event: its permission prompt arrives as
    // PermissionRequest instead.
    #expect(groups["Notification"] == nil)
  }

  @Test func preToolUseOrdersAwaitingAfterBusy() throws {
    let preToolUse = try #require(try DevinHookSettings.hooksByEvent()["PreToolUse"])
    #expect(preToolUse.count == 2)
    #expect(preToolUse.first?.objectValue?["matcher"]?.stringValue == "")
    // Devin hook matchers see snake_case tool names.
    #expect(preToolUse.last?.objectValue?["matcher"]?.stringValue == "ask_user_question|exit_plan_mode")
  }

  @Test func everyCommandCarriesOwnershipSentinel() throws {
    let commands = try Self.commandStrings(from: try DevinHookSettings.hooksByEvent())
    #expect(commands.allSatisfy { $0.contains(AgentHookSettingsCommand.ownershipMarker) })
  }

  @Test func everyCommandTargetsDevinAgent() throws {
    let commands = try Self.commandStrings(from: try DevinHookSettings.hooksByEvent())
    #expect(commands.allSatisfy { $0.contains("start=devin;") })
  }

  @Test func everyCommandOnlyNamesForwardedOrLocalVariables() throws {
    // The shared command shape is held to the Grok-motivated allowlist: a bare
    // `$VAR` is only ever a forwarded SUPACODE_* var or a `__` local.
    let commands = try Self.commandStrings(from: try DevinHookSettings.hooksByEvent())
    #expect(!commands.isEmpty)
    #expect(commands.allSatisfy { !ManagedHookCommandVariables.names(in: $0).isEmpty })
    #expect(commands.allSatisfy { ManagedHookCommandVariables.unexpected(in: $0).isEmpty })
  }

  @Test func stopCommandReadsLastAssistantMessageForNotifyBody() throws {
    // Devin's Stop hook stdin includes `last_assistant_message` (per the Devin
    // CLI changelog), matching Claude Code. The notify body is extracted from
    // that field rather than a fixed string.
    let stop = try #require(try DevinHookSettings.hooksByEvent()["Stop"])
    let commands = Self.commandStrings(in: stop)
    #expect(!commands.isEmpty)
    #expect(commands.allSatisfy { $0.contains("last_assistant_message") })
  }

  @Test func postToolUseFiresIdleNotBusy() throws {
    let postToolUse = try #require(try DevinHookSettings.hooksByEvent()["PostToolUse"])
    let commands = Self.commandStrings(in: postToolUse)
    #expect(commands.allSatisfy { $0.contains("event=idle") })
    #expect(commands.allSatisfy { !$0.contains("event=busy") })
  }

  @Test func permissionRequestFiresAwaitingInputAndFixedNotify() throws {
    // Devin has no Notification event, so a permission prompt would never reach
    // the stdin-sourced notify leg; it emits a fixed notify instead.
    let permissionRequest = try #require(try DevinHookSettings.hooksByEvent()["PermissionRequest"])
    let commands = Self.commandStrings(in: permissionRequest)
    #expect(commands.allSatisfy { $0.contains("event=awaiting_input") })
    #expect(commands.allSatisfy { $0.contains("kind=notify") })
    #expect(commands.allSatisfy { $0.contains("title=") && $0.contains("body=") })
  }

  @Test func devinEmittedLifecycleEventsParseAsPresence() throws {
    // Pin the emit-to-parse coupling end to end: pull each event's metadata
    // straight from the emitted OSC sequence and run it through the real parser,
    // so a HookEvent rename, a compositeCommand typo, or an OSC framing bug
    // can't silently kill presence over SSH.
    let commands = try Self.commandStrings(from: try DevinHookSettings.hooksByEvent())
    let signals = commands.flatMap { Self.parsedPresenceSignals(in: $0) }
    for event in ["session_start", "busy", "idle", "awaiting_input", "session_end"] {
      #expect(signals.contains { $0.agent == "devin" && $0.eventRawValue == event })
    }
  }

  @Test func timeoutsArePositive() throws {
    let groups = try DevinHookSettings.hooksByEvent()
    let timeouts = groups.values.flatMap { group in
      group.flatMap { entry in
        entry.objectValue?["hooks"]?.arrayValue?.compactMap { hook in
          Self.timeoutValue(from: hook.objectValue?["timeout"])
        } ?? []
      }
    }
    #expect(!timeouts.isEmpty)
    #expect(timeouts.allSatisfy { $0 > 0 })
  }

  private static func timeoutValue(from value: JSONValue?) -> Int? {
    guard let value else { return nil }
    switch value {
    case .int(let timeout): return timeout
    case .double(let timeout): return Int(timeout)
    default: return nil
    }
  }

  /// Parse every OSC 3008 presence signal a composite command emits, mirroring
  /// libghostty's `id;metadata` split. The `%s` pid placeholder is dropped to
  /// match the no-pid remote wire the parser receives over SSH.
  private static func parsedPresenceSignals(in command: String) -> [AgentPresenceOSC.Signal] {
    command.components(separatedBy: "]3008;").dropFirst().compactMap { chunk in
      guard let stEnd = chunk.range(of: #"\033"#) else { return nil }
      let sequence = chunk[..<stEnd.lowerBound].replacing("%s", with: "")
      guard let idEnd = sequence.firstIndex(of: ";") else { return nil }
      return AgentPresenceOSC.parse(id: "devin", metadata: String(sequence[sequence.index(after: idEnd)...]))
    }
  }

  private static func commandStrings(from groups: [String: [JSONValue]]) -> [String] {
    groups.values.flatMap { commandStrings(in: $0) }
  }

  private static func commandStrings(in groups: [JSONValue]) -> [String] {
    groups.flatMap { group in
      group.objectValue?["hooks"]?.arrayValue?.compactMap {
        $0.objectValue?["command"]?.stringValue
      } ?? []
    }
  }
}
