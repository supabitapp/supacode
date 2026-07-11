import Foundation
import Testing

@testable import SupacodeSettingsShared

struct GrokHookSettingsTests {
  @Test func hooksByEventCoverCoreEvents() throws {
    let groups = try GrokHookSettings.hooksByEvent()
    #expect(groups["SessionStart"] != nil)
    #expect(groups["UserPromptSubmit"] != nil)
    #expect(groups["PreToolUse"] != nil)
    #expect(groups["PostToolUse"] != nil)
    #expect(groups["Notification"] != nil)
    #expect(groups["Stop"] != nil)
    #expect(groups["SessionEnd"] != nil)
  }

  @Test func preToolUseOrdersAwaitingAfterBusy() throws {
    let preToolUse = try #require(try GrokHookSettings.hooksByEvent()["PreToolUse"])
    #expect(preToolUse.count == 2)
    #expect(preToolUse.first?.objectValue?["matcher"]?.stringValue == "")
    #expect(preToolUse.last?.objectValue?["matcher"]?.stringValue == "AskUserQuestion|ExitPlanMode")
  }

  @Test func everyCommandCarriesOwnershipSentinel() throws {
    let commands = try Self.commandStrings(from: try GrokHookSettings.hooksByEvent())
    #expect(commands.allSatisfy { $0.contains(AgentHookSettingsCommand.ownershipMarker) })
  }

  @Test func everyHookForwardsSupacodeEnv() throws {
    let groups = try GrokHookSettings.hooksByEvent()
    let expected = AgentHookSettingsCommand.grokHookEnvPassthrough
    // Walk every command-bearing hook (not compactMap on env) so a single
    // missing env block fails rather than being silently dropped.
    let hooks = groups.values.flatMap { group in
      group.flatMap { entry in
        entry.objectValue?["hooks"]?.arrayValue ?? []
      }
    }
    #expect(!hooks.isEmpty)
    for hook in hooks {
      let hookObject = try #require(hook.objectValue)
      #expect(hookObject["command"]?.stringValue != nil)
      let env = try #require(hookObject["env"]?.objectValue)
      #expect(expected.allSatisfy { key, value in env[key]?.stringValue == value })
    }
  }

  @Test func everyCommandTargetsGrokAgent() throws {
    let commands = try Self.commandStrings(from: try GrokHookSettings.hooksByEvent())
    #expect(commands.allSatisfy { $0.contains("start=grok;") })
  }

  @Test func postToolUseFiresIdleNotBusy() throws {
    let postToolUse = try #require(try GrokHookSettings.hooksByEvent()["PostToolUse"])
    let commands = Self.commandStrings(in: postToolUse)
    #expect(commands.allSatisfy { $0.contains("event=idle") })
    #expect(commands.allSatisfy { !$0.contains("event=busy") })
  }

  @Test func grokEmittedLifecycleEventsParseAsPresence() throws {
    // Pin the emit-to-parse coupling end to end: pull each event's metadata
    // straight from the emitted OSC sequence and run it through the real parser,
    // so a HookEvent rename, a compositeCommand typo, or an OSC framing bug
    // can't silently kill presence over SSH.
    let commands = try Self.commandStrings(from: try GrokHookSettings.hooksByEvent())
    let signals = commands.flatMap { Self.parsedPresenceSignals(in: $0) }
    for event in ["session_start", "busy", "idle", "awaiting_input", "session_end"] {
      #expect(signals.contains { $0.agent == "grok" && $0.eventRawValue == event })
    }
  }

  @Test func timeoutsArePositive() throws {
    let groups = try GrokHookSettings.hooksByEvent()
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
      return AgentPresenceOSC.parse(id: "grok", metadata: String(sequence[sequence.index(after: idEnd)...]))
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
