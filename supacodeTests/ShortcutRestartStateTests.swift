import Testing

@testable import supacode

@MainActor
struct ShortcutRestartStateTests {
  @Test func requiresRestartReturnsFalseWhenMatchingLaunchOverrides() {
    let launchOverrides = ShortcutRestartState.launchOverrides
    #expect(!ShortcutRestartState.requiresRestart(current: launchOverrides))
  }

  @Test func requiresRestartReturnsTrueWhenOverrideAdded() {
    var current = ShortcutRestartState.launchOverrides
    current["newWorktree"] = AppShortcutOverride(keyCode: 0x00, modifiers: [.command, .shift])
    #expect(ShortcutRestartState.requiresRestart(current: current))
  }

  @Test func requiresRestartReturnsTrueWhenDifferentOverrides() {
    var current = ShortcutRestartState.launchOverrides
    current["toggleLeftSidebar"] = AppShortcutOverride(keyCode: 0x00, modifiers: [.command, .shift])
    #expect(ShortcutRestartState.requiresRestart(current: current))
  }

  @Test func requiresRestartDetectsRemovedOverride() {
    let launch = ShortcutRestartState.launchOverrides
    var modified = launch
    modified["extraShortcut"] = AppShortcutOverride(keyCode: 0x01, modifiers: [.command])
    #expect(ShortcutRestartState.requiresRestart(current: modified))
    #expect(!ShortcutRestartState.requiresRestart(current: launch))
  }
}
