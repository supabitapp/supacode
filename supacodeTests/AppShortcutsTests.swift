import AppKit
import Carbon.HIToolbox
import CustomDump
import SwiftUI
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

private struct PlainCodingKey: CodingKey {
  var stringValue: String
  var intValue: Int? { nil }
  init(_ stringValue: String) { self.stringValue = stringValue }
  init?(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { nil }
}

@MainActor
struct AppShortcutsTests {
  private static func keyEvent(keyCode: Int, modifiers: NSEvent.ModifierFlags) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: modifiers,
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: "p",
      charactersIgnoringModifiers: "p",
      isARepeat: false,
      keyCode: UInt16(keyCode)
    )!
  }

  @Test func matchesRequiresAnExactModifierSet() {
    let worktreeSwitcher = AppShortcuts.worktreeSwitcher  // ⌘P.
    let commandPalette = AppShortcuts.commandPalette  // ⌘⇧P.

    let command = Self.keyEvent(keyCode: kVK_ANSI_P, modifiers: .command)
    #expect(worktreeSwitcher.matches(command))
    // ⌘P must not match ⌘⇧P: a character-based match would invert the two palettes.
    #expect(commandPalette.matches(command) == false)

    let commandShift = Self.keyEvent(keyCode: kVK_ANSI_P, modifiers: [.command, .shift])
    #expect(commandPalette.matches(commandShift))
    #expect(worktreeSwitcher.matches(commandShift) == false)

    // A superset of the bound modifiers is not a match.
    let commandOption = Self.keyEvent(keyCode: kVK_ANSI_P, modifiers: [.command, .option])
    #expect(worktreeSwitcher.matches(commandOption) == false)
    #expect(commandPalette.matches(commandOption) == false)
  }

  @Test func matchesIgnoresIncidentalModifierFlags() {
    // Caps Lock (and the function / numeric-pad flags) must not defeat the match.
    let event = Self.keyEvent(keyCode: kVK_ANSI_P, modifiers: [.command, .capsLock, .function])
    #expect(AppShortcuts.worktreeSwitcher.matches(event))
  }

  @Test func matchesFollowsUserRebind() {
    let overrides: [AppShortcutID: AppShortcutOverride] = [
      .worktreeSwitcher: AppShortcutOverride(keyCode: UInt16(kVK_ANSI_K), modifiers: .command)
    ]
    let rebound = AppShortcuts.worktreeSwitcher.effective(from: overrides)

    #expect(rebound?.matches(Self.keyEvent(keyCode: kVK_ANSI_K, modifiers: .command)) == true)
    // The default chord stops matching once the user rebinds it.
    #expect(rebound?.matches(Self.keyEvent(keyCode: kVK_ANSI_P, modifiers: .command)) == false)
  }

  @Test func disabledShortcutResolvesToNoMatcher() {
    let overrides: [AppShortcutID: AppShortcutOverride] = [.worktreeSwitcher: .disabled]
    // A disabled shortcut has no effective binding, so the palette never matches its chord.
    #expect(AppShortcuts.worktreeSwitcher.effective(from: overrides) == nil)
  }

  @Test func matchesIsAlwaysFalseForSpecialKeyShortcuts() {
    // Shortcuts built from a bare key equivalent (⌘⌫, ⌘⏎, ...) carry no key code, so
    // `matches` reports false rather than guessing. Pinned so a future caller does not
    // read the silent no-match as a bug.
    let event = Self.keyEvent(keyCode: kVK_Delete, modifiers: .command)
    #expect(AppShortcuts.archiveWorktree.matches(event) == false)
  }

  @Test func matchesFollowsRebindOntoAKeypadKey() {
    // A keypad digit prints the same character as its main-row twin, so resolving the code
    // back from the character would answer the wrong physical key. The rebind's own code wins.
    let overrides: [AppShortcutID: AppShortcutOverride] = [
      .worktreeSwitcher: AppShortcutOverride(keyCode: UInt16(kVK_ANSI_Keypad1), modifiers: .command)
    ]
    let rebound = AppShortcuts.worktreeSwitcher.effective(from: overrides)

    #expect(rebound?.matches(Self.keyEvent(keyCode: kVK_ANSI_Keypad1, modifiers: .command)) == true)
    #expect(rebound?.matches(Self.keyEvent(keyCode: kVK_ANSI_1, modifiers: .command)) == false)
  }

  @Test func matchesFollowsRebindOntoASpecialKey() {
    // A special key has no printable equivalent to resolve, so the match falls back to
    // the code the rebind stored. Without it the menu would open the palette on ⌘⏎ while
    // the panel refused to close on the same chord.
    let overrides: [AppShortcutID: AppShortcutOverride] = [
      .worktreeSwitcher: AppShortcutOverride(keyCode: UInt16(kVK_Return), modifiers: .command)
    ]
    let rebound = AppShortcuts.worktreeSwitcher.effective(from: overrides)

    #expect(rebound?.matches(Self.keyEvent(keyCode: kVK_Return, modifiers: .command)) == true)
    #expect(rebound?.matches(Self.keyEvent(keyCode: kVK_ANSI_P, modifiers: .command)) == false)
  }

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
      ["⌃1", "⌃2", "⌃3", "⌃4", "⌃5", "⌃6", "⌃7", "⌃8", "⌃9"]
    )

    for shortcut in AppShortcuts.worktreeSelection {
      #expect(shortcut.modifiers == .control)
    }
  }

  @Test func tabSelectionGhosttyKeybindArgumentsMatchExpected() {
    expectNoDifference(
      AppShortcuts.tabSelectionGhosttyKeybindArguments(from: [:]),
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
      ]
    )
  }

  @Test func ghosttyCLIArgumentsKeepWorktreeUnbindsAndTabBinds() {
    let arguments = AppShortcuts.ghosttyCLIKeybindArguments

    for shortcut in AppShortcuts.worktreeSelection {
      #expect(arguments.contains(shortcut.ghosttyUnbindArgument))
    }

    for argument in AppShortcuts.tabSelectionGhosttyKeybindArguments(from: [:]) {
      #expect(arguments.contains(argument))
    }

    for argument in ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"].map({ "--keybind=ctrl+digit_\($0)=unbind" }) {
      #expect(arguments.contains(argument) == false)
    }
  }

  // MARK: - Tab selection honors overrides.

  @Test func tabSelectionOmitsDisabledWorktreeSelection() {
    let arguments = AppShortcuts.tabSelectionGhosttyKeybindArguments(
      from: [.selectWorktree(6): .disabled]
    )
    // The disabled slot contributes no goto_tab binding, so ⌃6 reaches the terminal.
    #expect(arguments.contains("--keybind=ctrl+6=goto_tab:6") == false)
    #expect(arguments.contains("--keybind=ctrl+digit_6=goto_tab:6") == false)
    // Other slots are unaffected.
    #expect(arguments.contains("--keybind=ctrl+5=goto_tab:5"))
  }

  @Test func tabSelectionFollowsRemappedWorktreeSelection() {
    let override = AppShortcutOverride(keyCode: UInt16(kVK_ANSI_J), modifiers: [.command])
    let arguments = AppShortcuts.tabSelectionGhosttyKeybindArguments(
      from: [.selectWorktree(1): override]
    )
    // The goto_tab binding moves to the remapped chord; the default ⌃1 is released.
    #expect(arguments.contains("--keybind=super+j=goto_tab:1"))
    #expect(arguments.contains("--keybind=ctrl+1=goto_tab:1") == false)
    #expect(arguments.contains("--keybind=ctrl+digit_1=goto_tab:1") == false)
  }

  @Test func ghosttyCLIArgumentsReleaseDisabledWorktreeChordToTerminal() {
    let arguments = AppShortcuts.ghosttyCLIKeybindArguments(from: [.selectWorktree(6): .disabled])
    // Neither a goto_tab binding nor an unbind remains, so ⌃6 is delivered to the terminal.
    #expect(arguments.contains { $0.hasPrefix("--keybind=ctrl+6=") } == false)
    #expect(arguments.contains(AppShortcuts.selectWorktree6.ghosttyUnbindArgument) == false)
  }

  @Test func ghosttyCLIArgumentsMoveRemappedWorktreeChord() {
    let override = AppShortcutOverride(keyCode: UInt16(kVK_ANSI_J), modifiers: [.command])
    let arguments = AppShortcuts.ghosttyCLIKeybindArguments(from: [.selectWorktree(1): override])
    #expect(arguments.contains("--keybind=super+j=goto_tab:1"))
    #expect(arguments.contains { $0.hasPrefix("--keybind=ctrl+1=") } == false)
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
    #expect(AppShortcuts.selectWorktree9.displayName == "Select Worktree 9")
    #expect(AppShortcutID.selectWorktree(0).displayName == "Select Worktree 10")
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

  // MARK: - Disabled by default.

  @Test func disabledByDefaultShortcutIsInactiveUntilOverridden() {
    #expect(AppShortcuts.cloneRepository.isEnabledByDefault == false)
    #expect(AppShortcuts.cloneRepository.effective(from: [:]) == nil)
    let override = AppShortcutOverride(keyCode: UInt16(kVK_ANSI_O), modifiers: [.command, .option, .shift])
    #expect(AppShortcuts.cloneRepository.effective(from: [.cloneRepository: override]) != nil)
  }

  @Test func defaultEnabledOverrideBindsOnlyDisabledByDefaultShortcuts() throws {
    let override = try #require(AppShortcuts.defaultEnabledOverride(for: .cloneRepository))
    #expect(override.isEnabled)
    let effective = AppShortcuts.cloneRepository.effective(from: [.cloneRepository: override])
    #expect(effective?.display == AppShortcuts.cloneRepository.display)
    // An enabled-by-default shortcut needs no override to be active.
    #expect(AppShortcuts.defaultEnabledOverride(for: .openRepository) == nil)
  }

  // MARK: - Active worktree selection slots.

  @Test func activeSlotsIncludeAllWhenNoOverrideAndRowsMatch() {
    let slots = AppShortcuts.activeWorktreeSelectionSlots(overrides: [:], orderedRowsCount: 9)
    #expect(slots.map(\.index) == [0, 1, 2, 3, 4, 5, 6, 7, 8])
    expectNoDifference(slots.map(\.shortcut.display), AppShortcuts.worktreeSelection.map(\.display))
  }

  @Test func activeSlotsDropDisabledOverridePreservingOtherIndices() {
    let slots = AppShortcuts.activeWorktreeSelectionSlots(
      overrides: [.selectWorktree(6): .disabled],
      orderedRowsCount: 9
    )
    #expect(slots.map(\.index) == [0, 1, 2, 3, 4, 6, 7, 8])
    #expect(slots.allSatisfy { $0.index != 5 })
  }

  @Test func activeSlotsDropOutOfRangeOrderedRows() {
    let slots = AppShortcuts.activeWorktreeSelectionSlots(overrides: [:], orderedRowsCount: 3)
    #expect(slots.map(\.index) == [0, 1, 2])
  }

  @Test func activeSlotsDropBothDisabledAndOutOfRangeSlots() {
    let slots = AppShortcuts.activeWorktreeSelectionSlots(
      overrides: [.selectWorktree(3): .disabled],
      orderedRowsCount: 5
    )
    #expect(slots.map(\.index) == [0, 1, 3, 4])
  }

  // MARK: - Worktree selection shortcut display.

  @Test func worktreeSelectionShortcutDisplayReturnsNilForOutOfRange() {
    #expect(AppShortcuts.worktreeSelectionShortcutDisplay(atSlot: -1, overrides: [:]) == nil)
    #expect(AppShortcuts.worktreeSelectionShortcutDisplay(atSlot: 10, overrides: [:]) == nil)
  }

  @Test func worktreeSelectionShortcutDisplayReturnsNilForDisabledSlot() {
    #expect(
      AppShortcuts.worktreeSelectionShortcutDisplay(
        atSlot: 2,
        overrides: [.selectWorktree(3): .disabled]
      ) == nil
    )
  }

  @Test func worktreeSelectionShortcutDisplayReturnsEffectiveDisplay() {
    #expect(
      AppShortcuts.worktreeSelectionShortcutDisplay(atSlot: 6, overrides: [:]) == "⌃7"
    )
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
      ["General", "Sidebar", "Worktrees", "Worktree Selection", "Tab Selection", "Actions"]
    )
  }

  // MARK: - Groups match categories.

  @Test func groupsCategoriesMatchAllCases() {
    let groupCategories = AppShortcuts.groups.map(\.category)
    expectNoDifference(groupCategories, AppShortcutCategory.allCases)
  }

  // MARK: - Backward-compatible key migration.

  @Test func legacyOpenFinderKeyDecodesToOpenWorktree() {
    // Existing user settings may contain "openFinder" from before the rename.
    let decoded = AppShortcutID(codingKey: PlainCodingKey("openFinder"))
    #expect(decoded == .openWorktree)
  }

  @Test func openWorktreeKeyRoundTrips() {
    let decoded = AppShortcutID(codingKey: PlainCodingKey("openWorktree"))
    #expect(decoded == .openWorktree)
    #expect(decoded?.codingKey.stringValue == "openWorktree")
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

  // MARK: - Inspector pane shortcuts.

  @Test func inspectorShortcutKeysRoundTrip() {
    for id in [AppShortcutID.togglePullRequestInspector, .toggleNotificationsInspector] {
      let decoded = AppShortcutID(codingKey: PlainCodingKey(id.codingKey.stringValue))
      #expect(decoded == id)
    }
  }

  @Test func inspectorShortcutsHaveNoDefaultConflict() {
    let warnings = AppShortcuts.conflictWarnings(from: [:])
    #expect(warnings[.togglePullRequestInspector] == nil)
    #expect(warnings[.toggleNotificationsInspector] == nil)
  }

  @Test func inspectorShortcutsUnbindInGhostty() {
    #expect(AppShortcuts.togglePullRequestInspector.ghosttyUnbindArgument == "--keybind=alt+super+g=unbind")
    #expect(AppShortcuts.toggleNotificationsInspector.ghosttyUnbindArgument == "--keybind=alt+super+n=unbind")
    let arguments = AppShortcuts.ghosttyCLIKeybindArguments
    #expect(arguments.contains("--keybind=alt+super+g=unbind"))
    #expect(arguments.contains("--keybind=alt+super+n=unbind"))
  }
}
