import Foundation
import Testing

@testable import SupacodeSettingsShared

struct KimiHookSettingsTests {
  @Test func canonicalEntriesCoverCoreEvents() {
    let entries = KimiHookSettings.canonicalEntries()
    let events = entries.map(\.event)
    #expect(events.contains("SessionStart"))
    #expect(events.contains("UserPromptSubmit"))
    #expect(events.contains("PreToolUse"))
    #expect(events.contains("PostToolUse"))
    #expect(events.contains("Notification"))
    #expect(events.contains("Stop"))
    #expect(events.contains("SessionEnd"))
  }

  @Test func canonicalEntriesCarryMatcherForAwaitingInputSlot() {
    let entries = KimiHookSettings.canonicalEntries()
    let preToolUse = entries.filter { $0.event == "PreToolUse" }
    #expect(preToolUse.count == 2)
    let matchers = preToolUse.map(\.matcher)
    #expect(matchers.contains(""))
    #expect(matchers.contains("AskUserQuestion|ExitPlanMode"))
  }

  @Test func everyCommandCarriesOwnershipSentinel() {
    let entries = KimiHookSettings.canonicalEntries()
    #expect(entries.allSatisfy { $0.command.contains(AgentHookSettingsCommand.ownershipMarker) })
  }

  @Test func everyCommandTargetsKimiAgent() {
    let entries = KimiHookSettings.canonicalEntries()
    #expect(entries.allSatisfy { $0.command.contains("start=kimi;") })
  }

  @Test func timeoutsArePositive() {
    let entries = KimiHookSettings.canonicalEntries()
    #expect(entries.allSatisfy { $0.timeout > 0 })
  }
}
