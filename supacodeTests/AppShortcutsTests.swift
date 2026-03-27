import Carbon.HIToolbox
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
    let arguments = AppShortcuts.ghosttyCLIKeybindArguments

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

  // MARK: - Shortcut identity.

  @Test func allShortcutsHaveUniqueIDs() {
    let ids = AppShortcuts.all.map(\.id)
    #expect(Set(ids).count == ids.count)
  }

  @Test func displayNameFromID() {
    #expect(AppShortcuts.newWorktree.displayName == "New Worktree")
    #expect(AppShortcuts.openPullRequest.displayName == "Open Pull Request")
    #expect(AppShortcuts.toggleLeftSidebar.displayName == "Toggle Left Sidebar")
    #expect(AppShortcuts.selectWorktree1.displayName == "Select Worktree 1")
    #expect(AppShortcuts.selectWorktree0.displayName == "Select Worktree 10")
  }

  // MARK: - Effective shortcut resolution.

  @Test func effectiveReturnsDefaultWhenNoOverride() {
    let result = AppShortcuts.newWorktree.effective(from: [:])
    #expect(result?.display == AppShortcuts.newWorktree.display)
  }

  @Test func effectiveReturnsOverrideWhenPresent() {
    let override = AppShortcutOverride(
      keyCode: UInt16(kVK_ANSI_R),
      modifiers: [.command, .shift]
    )
    let result = AppShortcuts.newWorktree.effective(from: [.newWorktree: override])
    #expect(result?.display == "⌘⇧R")
  }

  @Test func ghosttyCLIArgumentsWithOverrides() {
    let override = AppShortcutOverride(
      keyCode: UInt16(kVK_ANSI_K),
      modifiers: [.command]
    )
    let args = AppShortcuts.ghosttyCLIKeybindArguments(from: [.newWorktree: override])
    // The override should produce an unbind for super+k instead of super+n.
    #expect(args.contains("--keybind=super+k=unbind"))
    #expect(!args.contains("--keybind=super+n=unbind"))
  }

  // MARK: - Groups.

  @Test func groupsCoverAllShortcuts() {
    let groupIDs = Set(AppShortcuts.groups.flatMap(\.shortcuts).map(\.id))
    let allIDs = Set(AppShortcuts.all.map(\.id))
    #expect(groupIDs == allIDs)
  }

  // MARK: - Effective shortcut disabled.

  @Test func effectiveReturnsNilWhenDisabled() {
    let result = AppShortcuts.newWorktree.effective(from: [.newWorktree: .disabled])
    #expect(result == nil)
  }

  @Test func effectiveReturnsNilWhenOverrideHasIsEnabledFalse() {
    let override = AppShortcutOverride(
      keyCode: UInt16(kVK_ANSI_K),
      modifiers: [.command],
      isEnabled: false
    )
    let result = AppShortcuts.newWorktree.effective(from: [.newWorktree: override])
    #expect(result == nil)
  }

  // MARK: - Ghostty unbind argument format.

  @Test func ghosttyUnbindArgument() {
    let shortcut = AppShortcuts.openSettings
    #expect(shortcut.ghosttyUnbindArgument.hasPrefix("--keybind="))
    #expect(shortcut.ghosttyUnbindArgument.hasSuffix("=unbind"))
  }

  // MARK: - CLI arguments with disabled overrides.

  @Test func ghosttyCLIArgumentsExcludeDisabledShortcuts() {
    let args = AppShortcuts.ghosttyCLIKeybindArguments(from: [.newWorktree: .disabled])
    // A disabled shortcut should not appear in the unbind list.
    let defaultUnbind = AppShortcuts.newWorktree.ghosttyUnbindArgument
    #expect(!args.contains(defaultUnbind))
  }

  // MARK: - Category display names.

  @Test func categoryDisplayNames() {
    expectNoDifference(
      AppShortcutCategory.allCases.map(\.displayName),
      ["General", "Sidebar", "Worktrees", "Worktree Selection", "Actions"]
    )
  }

  // MARK: - Groups match categories.

  @Test func groupsCategoriesMatchAllCases() {
    let groupCategories = AppShortcuts.groups.map(\.category)
    expectNoDifference(groupCategories, AppShortcutCategory.allCases)
  }

  // MARK: - Override ghost keybind propagation.

  @Test func effectiveOverrideGhosttyKeybindMatchesOverrideKeybind() {
    let override = AppShortcutOverride(
      keyCode: UInt16(kVK_ANSI_R),
      modifiers: [.command, .shift]
    )
    let effective = AppShortcuts.newWorktree.effective(from: [.newWorktree: override])
    #expect(effective != nil)
    #expect(effective?.ghosttyKeybind == override.ghosttyKeybind)
  }
}
