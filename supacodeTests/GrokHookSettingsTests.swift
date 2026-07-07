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
    // Pin the emit-to-parse coupling end to end: each composite command still
    // carries the OSC event literal and the parser accepts it, so a HookEvent
    // rename or a compositeCommand typo can't silently kill presence over SSH.
    let commands = try Self.commandStrings(from: try GrokHookSettings.hooksByEvent())
    for event in ["session_start", "busy", "idle", "session_end"] {
      #expect(commands.contains { $0.contains("event=\(event)") })
      let signal = AgentPresenceOSC.parse(id: "grok", metadata: "event=\(event)")
      #expect(signal?.agent == "grok")
      #expect(signal?.eventRawValue == event)
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
