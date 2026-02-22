import CustomDump
import SwiftUI
import Testing

@testable import supacode

@MainActor
struct AppShortcutsTests {
  @Test func displaySymbolsMatchDisplay() {
    let shortcuts: [AppShortcut] = [
      AppShortcuts.openSettings,
      AppShortcuts.newWorktree,
      AppShortcuts.copyPath,
    ]

    for shortcut in shortcuts {
      expectNoDifference(shortcut.displaySymbols.joined(), shortcut.display)
    }
  }

  @Test func worktreeSelectionUsesControlNumberShortcuts() {
    expectNoDifference(
      AppShortcuts.worktreeSelection.map(\.display),
      ["⌃1", "⌃2", "⌃3", "⌃4", "⌃5", "⌃6", "⌃7", "⌃8", "⌃9", "⌃0"]
    )

    for shortcut in AppShortcuts.worktreeSelection {
      #expect(shortcut.modifiers == .control)
    }
  }

  @Test func tabSelectionGhosttyKeybindArgumentsMatchExpected() {
    expectNoDifference(
      AppShortcuts.tabSelectionGhosttyKeybindArguments,
      [
        "--keybind=ctrl+1=goto_tab:1",
        "--keybind=ctrl+digit_1=goto_tab:1",
        "--keybind=ctrl+2=goto_tab:2",
        "--keybind=ctrl+digit_2=goto_tab:2",
        "--keybind=ctrl+3=goto_tab:3",
        "--keybind=ctrl+digit_3=goto_tab:3",
        "--keybind=ctrl+4=goto_tab:4",
        "--keybind=ctrl+digit_4=goto_tab:4",
        "--keybind=ctrl+5=goto_tab:5",
        "--keybind=ctrl+digit_5=goto_tab:5",
        "--keybind=ctrl+6=goto_tab:6",
        "--keybind=ctrl+digit_6=goto_tab:6",
        "--keybind=ctrl+7=goto_tab:7",
        "--keybind=ctrl+digit_7=goto_tab:7",
        "--keybind=ctrl+8=goto_tab:8",
        "--keybind=ctrl+digit_8=goto_tab:8",
        "--keybind=ctrl+9=goto_tab:9",
        "--keybind=ctrl+digit_9=goto_tab:9",
        "--keybind=ctrl+0=goto_tab:10",
        "--keybind=ctrl+digit_0=goto_tab:10",
      ]
    )
  }

  @Test func ghosttyCLIArgumentsKeepWorktreeUnbindsAndTabBinds() {
    let arguments = AppShortcuts.ghosttyCLIKeybindArguments(from: .default)

    for shortcut in AppShortcuts.worktreeSelection {
      #expect(arguments.contains(shortcut.ghosttyUnbindArgument))
    }

    for argument in AppShortcuts.tabSelectionGhosttyKeybindArguments {
      #expect(arguments.contains(argument))
    }

    for argument in ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"].map({ "--keybind=ctrl+digit_\($0)=unbind" }) {
      #expect(arguments.contains(argument) == false)
    }
  }

  @Test func namePropertyReturnsCorrectValues() {
    #expect(AppShortcuts.toggleLeftSidebar.name == "toggleLeftSidebar")
    #expect(AppShortcuts.newWorktree.name == "newWorktree")
    #expect(AppShortcuts.openSettings.name == "openSettings")
    #expect(AppShortcuts.selectNextWorktree.name == "selectNextWorktree")
    #expect(AppShortcuts.selectWorktree1.name == "selectWorktree1")
  }

  @Test func effectiveReturnsDefaultWhenNoOverrideExists() {
    let settings = GlobalSettings.default
    let shortcut = AppShortcuts.toggleLeftSidebar
    let effective = shortcut.effective(from: settings)
    #expect(effective.name == shortcut.name)
    #expect(effective.keyEquivalent == shortcut.keyEquivalent)
    #expect(effective.modifiers == shortcut.modifiers)
    #expect(effective.ghosttyKeybind == shortcut.ghosttyKeybind)
  }

  @Test func effectiveReturnsOverriddenShortcut() {
    let override = AppShortcutOverride(keyCode: 0x00, modifiers: [.command, .shift])
    var settings = GlobalSettings.default
    settings.shortcutOverrides = ["toggleLeftSidebar": override]
    let effective = AppShortcuts.toggleLeftSidebar.effective(from: settings)
    #expect(effective.name == "toggleLeftSidebar")
    #expect(effective.keyEquivalent == KeyEquivalent("a"))
    #expect(effective.modifiers == [.command, .shift])
    #expect(effective.ghosttyKeybind == "shift+super+a")
  }

  @Test func effectiveAllResolvesOverridesAndDefaults() {
    let override = AppShortcutOverride(keyCode: 0x01, modifiers: [.command, .shift])
    var settings = GlobalSettings.default
    settings.shortcutOverrides = ["newWorktree": override]
    let effective = AppShortcuts.effectiveAll(from: settings)
    let newWorktree = effective.first { $0.name == "newWorktree" }
    let openSettings = effective.first { $0.name == "openSettings" }
    #expect(newWorktree?.keyEquivalent == KeyEquivalent("s"))
    #expect(newWorktree?.modifiers == [.command, .shift])
    #expect(newWorktree?.ghosttyKeybind == "shift+super+s")
    #expect(openSettings?.keyEquivalent == AppShortcuts.openSettings.keyEquivalent)
    #expect(openSettings?.modifiers == AppShortcuts.openSettings.modifiers)
  }
}
