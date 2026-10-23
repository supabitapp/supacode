import AppKit
import Carbon.HIToolbox
import CustomDump
import IdentifiedCollections
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

  @Test func matchesResolvesSpecialKeyShortcutsThroughTheFixedTable() {
    // Shortcuts built from a bare key equivalent (⌘⌫, ⌘⏎, ...) carry no key
    // code; the fixed special-key table supplies it so pane windows can match
    // arrow and return chords.
    let event = Self.keyEvent(keyCode: kVK_Delete, modifiers: .command)
    #expect(AppShortcuts.archiveWorktree.matches(event))
    #expect(AppShortcuts.archiveWorktree.matches(Self.keyEvent(keyCode: kVK_ANSI_P, modifiers: .command)) == false)
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

  @Test func tabSelectionShortcutDisplaysFallBackToDefaults() {
    expectNoDifference(
      AppShortcuts.tabSelectionShortcutDisplays(overrides: [:]),
      ["⌘1", "⌘2", "⌘3", "⌘4", "⌘5", "⌘6", "⌘7", "⌘8", "⌘9"]
    )
  }

  @Test func tabSelectionShortcutDisplaysFollowOverride() {
    let displays = AppShortcuts.tabSelectionShortcutDisplays(
      overrides: [.selectTab(1): AppShortcutOverride(keyCode: UInt16(kVK_ANSI_1), modifiers: .control)]
    )

    expectNoDifference(displays[0], "⌃1")
    expectNoDifference(displays[1], "⌘2")
  }

  @Test func tabSelectionShortcutDisplaysAreNilWhenDisabled() {
    let displays = AppShortcuts.tabSelectionShortcutDisplays(overrides: [.selectTab(3): .disabled])

    #expect(displays[2] == nil)
    expectNoDifference(displays[3], "⌘4")
  }

  @Test func ghosttyKeybindConfigLinesUnbindWorktreeSelection() {
    let lines = AppShortcuts.ghosttyKeybindConfigLines(from: [:])

    for shortcut in AppShortcuts.worktreeSelection {
      guard let line = shortcut.ghosttyUnbindConfigLine else {
        Issue.record("\(shortcut.displayName) has no unbind line")
        continue
      }
      #expect(lines.contains(line))
    }
  }

  @Test func ghosttyKeybindConfigLinesReleaseDisabledWorktreeChordToTerminal() {
    let lines = AppShortcuts.ghosttyKeybindConfigLines(from: [.selectWorktree(6): .disabled])
    // No unbind remains, so a user-configured ⌃6 terminal binding keeps working.
    #expect(lines.contains { $0.hasPrefix("keybind = ctrl+6=") } == false)
    #expect(lines.contains { $0 == AppShortcuts.selectWorktree6.ghosttyUnbindConfigLine } == false)
  }

  @Test func ghosttyKeybindConfigLinesMoveRemappedWorktreeChord() {
    let override = AppShortcutOverride(keyCode: UInt16(kVK_ANSI_J), modifiers: [.command])
    let lines = AppShortcuts.ghosttyKeybindConfigLines(from: [.selectWorktree(1): override])
    // The remapped chord is claimed from the terminal; the default ⌃1 is released.
    #expect(lines.contains("keybind = super+j=unbind"))
    #expect(lines.contains { $0.hasPrefix("keybind = ctrl+1=") } == false)
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
    #expect(AppShortcuts.renameTab.displayName == "Rename Tab")
  }

  @Test func toggleWindowModeKeyRoundTrips() {
    let decoded = AppShortcutID(codingKey: PlainCodingKey("toggleWindowMode"))
    #expect(decoded == .toggleWindowMode)
    #expect(decoded?.codingKey.stringValue == "toggleWindowMode")
  }

  @Test func toggleWindowModeShortcutHasNoDefaultConflict() {
    #expect(AppShortcuts.conflictWarnings(from: [:])[.toggleWindowMode] == nil)
  }

  @Test func toggleWindowModeShortcutUnbindsInGhostty() {
    #expect(AppShortcuts.toggleWindowMode.ghosttyUnbindConfigLine == "keybind = shift+super+m=unbind")
    #expect(
      AppShortcuts.ghosttyKeybindConfigLines(from: [:])
        .contains { $0 == AppShortcuts.toggleWindowMode.ghosttyUnbindConfigLine }
    )
  }

  @Test func returnKeyedShortcutsUnbindWithGhosttyEnterToken() {
    // Ghostty 1.2+ names the key `enter`; the legacy `return` token fails to
    // parse and silently leaves the default chord bound inside Ghostty.
    #expect(AppShortcuts.toggleSplitZoom.ghosttyUnbindConfigLine == "keybind = shift+super+enter=unbind")
    #expect(AppShortcuts.confirmWorktreeAction.ghosttyUnbindConfigLine == "keybind = super+enter=unbind")
    let lines = AppShortcuts.ghosttyKeybindConfigLines(from: [:])
    #expect(lines.contains("keybind = shift+super+enter=unbind"))
    #expect(lines.contains("keybind = super+enter=unbind"))
  }

  @Test func everyShortcutKeyRoundTripsThroughTheDecodeMap() {
    // A stable key missing from the decode map does not merely drop the
    // override: the dictionary decode throws and the whole settings file
    // resets to defaults.
    for id in AppShortcuts.all.map(\.id) {
      let key = id.codingKey.stringValue
      #expect(AppShortcutID(codingKey: PlainCodingKey(key)) == id, "\(key) does not round-trip")
    }
  }

  @Test func renameTabKeyRoundTrips() {
    let decoded = AppShortcutID(codingKey: PlainCodingKey("renameTab"))
    #expect(decoded == .renameTab)
    #expect(decoded?.codingKey.stringValue == "renameTab")
  }

  @Test func renameTabShortcutHasNoDefaultConflict() {
    #expect(AppShortcuts.conflictWarnings(from: [:])[.renameTab] == nil)
  }

  @Test func renameTabShortcutUnbindsInGhostty() {
    #expect(AppShortcuts.renameTab.ghosttyUnbindConfigLine == "keybind = ctrl+shift+r=unbind")
    #expect(
      AppShortcuts.ghosttyKeybindConfigLines(from: [:])
        .contains { $0 == AppShortcuts.renameTab.ghosttyUnbindConfigLine }
    )
  }

  // MARK: - Non-customizable shortcuts.

  @Test func closeTabIsNotCustomizable() {
    #expect(AppShortcuts.closeTab.isCustomizable == false)
  }

  @Test func effectiveIgnoresOverridesForNonCustomizableShortcut() {
    let rebound = AppShortcutOverride(keyCode: UInt16(kVK_ANSI_K), modifiers: [.command])
    #expect(AppShortcuts.closeTab.effective(from: [.closeTab: rebound])?.display == "⌘W")
    #expect(AppShortcuts.closeTab.effective(from: [.closeTab: .disabled])?.display == "⌘W")
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

  @Test func ghosttyKeybindConfigLinesWithOverrides() {
    let override = AppShortcutOverride(
      keyCode: UInt16(kVK_ANSI_K),
      modifiers: [.command]
    )
    let lines = AppShortcuts.ghosttyKeybindConfigLines(from: [.newWorktree: override])
    // The override should produce an unbind for super+k instead of super+n.
    #expect(lines.contains("keybind = super+k=unbind"))
    #expect(!lines.contains("keybind = super+n=unbind"))
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

  // MARK: - Customize Appearance.

  @Test func customizeAppearanceKeyRoundTrips() {
    let decoded = AppShortcutID(codingKey: PlainCodingKey("customizeAppearance"))
    #expect(decoded == .customizeAppearance)
    #expect(decoded?.codingKey.stringValue == "customizeAppearance")
    #expect(AppShortcuts.customizeAppearance.displayName == "Customize Appearance")
  }

  @Test func customizeAppearanceIsListedUnderWorktrees() {
    let worktrees = AppShortcuts.groups.first { $0.category == .worktrees }
    #expect(worktrees?.shortcuts.contains { $0.id == .customizeAppearance } == true)
    #expect(AppShortcuts.customizeAppearance.isCustomizable)
  }

  @Test func customizeAppearanceShipsDisabledWithAnEnableableDefaultChord() throws {
    // The issue asks for the option to bind a chord, not a shipped one: off
    // until the settings toggle enables it, which binds the default ⌘⌃R.
    #expect(AppShortcuts.customizeAppearance.isEnabledByDefault == false)
    #expect(AppShortcuts.customizeAppearance.effective(from: [:]) == nil)
    let override = try #require(AppShortcuts.defaultEnabledOverride(for: .customizeAppearance))
    let enabled = AppShortcuts.customizeAppearance.effective(from: [.customizeAppearance: override])
    #expect(enabled?.display == "⌘⌃R")
    #expect(enabled?.display == AppShortcuts.customizeAppearance.display)
  }

  @Test func customizeAppearanceDefaultChordHasNoConflictOnceEnabled() throws {
    let override = try #require(AppShortcuts.defaultEnabledOverride(for: .customizeAppearance))
    let warnings = AppShortcuts.conflictWarnings(from: [.customizeAppearance: override])
    #expect(warnings[.customizeAppearance]?.contains("Conflicts with") != true)
  }

  @Test func customizeAppearanceUnbindsInGhosttyOnlyWhenEnabled() throws {
    // Off by default, the chord stays with the terminal; enabling it claims ⌘⌃R.
    #expect(AppShortcuts.customizeAppearance.ghosttyUnbindConfigLine == "keybind = ctrl+super+r=unbind")
    #expect(AppShortcuts.ghosttyKeybindConfigLines(from: [:]).contains("keybind = ctrl+super+r=unbind") == false)
    let override = try #require(AppShortcuts.defaultEnabledOverride(for: .customizeAppearance))
    let lines = AppShortcuts.ghosttyKeybindConfigLines(from: [.customizeAppearance: override])
    #expect(lines.contains("keybind = ctrl+super+r=unbind"))
  }

  @Test func customizeAppearanceFollowsUserRebind() {
    let overrides: [AppShortcutID: AppShortcutOverride] = [
      .customizeAppearance: AppShortcutOverride(keyCode: UInt16(kVK_ANSI_E), modifiers: [.command, .option])
    ]
    let rebound = AppShortcuts.customizeAppearance.effective(from: overrides)
    #expect(rebound?.display == "⌘⌥E")
    #expect(rebound?.matches(Self.keyEvent(keyCode: kVK_ANSI_E, modifiers: [.command, .option])) == true)
    #expect(rebound?.matches(Self.keyEvent(keyCode: kVK_ANSI_R, modifiers: [.command, .control])) == false)
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
    #expect(AppShortcuts.worktreeSelectionShortcutDisplay(atSlot: 9, overrides: [:]) == nil)
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

  // MARK: - Ghostty unbind config line format.

  @Test func ghosttyUnbindConfigLine() {
    let line = AppShortcuts.openSettings.ghosttyUnbindConfigLine
    #expect(line?.hasPrefix("keybind = ") == true)
    #expect(line?.hasSuffix("=unbind") == true)
  }

  // MARK: - Config lines with disabled overrides.

  @Test func ghosttyKeybindConfigLinesExcludeDisabledShortcuts() {
    let lines = AppShortcuts.ghosttyKeybindConfigLines(from: [.newWorktree: .disabled])
    // A disabled shortcut should not appear in the unbind list.
    #expect(lines.contains { $0 == AppShortcuts.newWorktree.ghosttyUnbindConfigLine } == false)
  }

  // MARK: - Category display names.

  @Test func categoryDisplayNames() {
    expectNoDifference(
      AppShortcutCategory.allCases.map(\.displayName),
      ["General", "Sidebar", "Worktrees", "Worktree Selection", "Layout", "Tab", "Actions"]
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
    for id in [AppShortcutID.togglePullRequestInspector, .toggleFilesInspector, .toggleNotificationsInspector] {
      let decoded = AppShortcutID(codingKey: PlainCodingKey(id.codingKey.stringValue))
      #expect(decoded == id)
    }
  }

  @Test func inspectorShortcutsHaveNoDefaultConflict() {
    let warnings = AppShortcuts.conflictWarnings(from: [:])
    #expect(warnings[.togglePullRequestInspector] == nil)
    #expect(warnings[.toggleFilesInspector] == nil)
    #expect(warnings[.toggleNotificationsInspector] == nil)
  }

  @Test func inspectorShortcutsUnbindInGhostty() {
    #expect(AppShortcuts.togglePullRequestInspector.ghosttyUnbindConfigLine == "keybind = alt+super+g=unbind")
    #expect(AppShortcuts.toggleFilesInspector.ghosttyUnbindConfigLine == "keybind = alt+super+f=unbind")
    #expect(AppShortcuts.toggleNotificationsInspector.ghosttyUnbindConfigLine == "keybind = alt+super+n=unbind")
    let lines = AppShortcuts.ghosttyKeybindConfigLines(from: [:])
    #expect(lines.contains("keybind = alt+super+g=unbind"))
    #expect(lines.contains("keybind = alt+super+f=unbind"))
    #expect(lines.contains("keybind = alt+super+n=unbind"))
  }

  // MARK: - Ghostty keybind grammar.

  @Test func everyDefaultShortcutProducesAParsableGhosttyKeybind() {
    for line in AppShortcuts.ghosttyKeybindConfigLines(from: [:]) {
      #expect(line.hasPrefix("keybind = "), "\(line) is not a keybind line")
      #expect(line.hasSuffix("=unbind"), "\(line) is not an unbind")
      #expect(!line.contains("0x"), "\(line) carries an unresolvable key name")
      #expect(!line.dropFirst("keybind = ".count).contains(" "), "\(line) has an unparsable chord")
    }
  }

  @Test func enabledEqualizeSplitsEmitsAnUnbindLine() {
    // The chord's key name is layout-resolved (`=` lives on ⇧0 on some
    // layouts), so assert presence rather than a literal spelling.
    guard let override = AppShortcuts.equalizeSplits.enabledOverride else {
      Issue.record("equalizeSplits has no enabled override")
      return
    }
    let overrides: [AppShortcutID: AppShortcutOverride] = [.equalizeSplits: override]
    let expected = AppShortcuts.equalizeSplits.effective(from: overrides)?.ghosttyUnbindConfigLine
    #expect(expected != nil)
    #expect(AppShortcuts.ghosttyKeybindConfigLines(from: overrides).contains { $0 == expected })
  }

  // MARK: - Reserved chords.

  @Test func appKitReservedStringsIncludeTheHardcodedCloseChord() {
    #expect(AppShortcutOverride.appKitReservedDisplayStrings == ["⌘Q", "⌘H", "⌘M", "⌘W"])
  }

  @Test func rebindingOntoCloseTabChordIsFlaggedAsAConflict() {
    let override = AppShortcutOverride(keyCode: UInt16(kVK_ANSI_W), modifiers: [.command])
    let warnings = AppShortcuts.conflictWarnings(from: [.runScript: override])
    #expect(warnings[.runScript]?.contains("Close Tab") == true)
    #expect(warnings[.closeTab]?.contains("Run Script") == true)
  }

  @Test func defaultShortcutChordsAreUnique() {
    let displays = AppShortcuts.all.compactMap { $0.effective(from: [:])?.display }
    #expect(Set(displays).count == displays.count)
  }

  // MARK: - Disabled-by-default round trip.

  @Test func everyDisabledByDefaultShortcutCanBeTurnedBackOn() {
    for shortcut in AppShortcuts.all where !shortcut.isEnabledByDefault {
      guard let override = AppShortcuts.defaultEnabledOverride(for: shortcut.id) else {
        Issue.record("\(shortcut.displayName) cannot be re-enabled from settings")
        continue
      }
      #expect(shortcut.effective(from: [shortcut.id: override]) != nil)
    }
  }

  // MARK: - Non-customizable unbind stability.

  @Test func closeTabStaysEffectiveAndUnboundUnderOverrides() {
    #expect(AppShortcuts.closeTab.effective(from: [.closeTab: .disabled]) != nil)
    let lines = AppShortcuts.ghosttyKeybindConfigLines(from: [.closeTab: .disabled])
    #expect(lines.contains("keybind = super+w=unbind"))
  }

}

@MainActor
struct PaneWindowShortcutTests {
  private static func keyEvent(
    keyCode: Int,
    modifiers: NSEvent.ModifierFlags,
    isARepeat: Bool = false
  ) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: modifiers,
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: "x",
      charactersIgnoringModifiers: "x",
      isARepeat: isARepeat,
      keyCode: UInt16(keyCode)
    )!
  }

  private static func tab(title: String = "Tab", isLocked: Bool = false) -> TabItem {
    TabItem(
      id: TabID(),
      title: title,
      content: ContentSnapshot(
        id: ContentID(),
        state: .terminal(TerminalContentState(workingDirectory: "/tmp/pane-window-shortcut"))
      ),
      isLocked: isLocked
    )
  }

  private static func pane(tabs: [TabItem]) -> Pane {
    Pane(id: PaneID(), tabs: IdentifiedArray(uniqueElements: tabs), selectedTabID: tabs.first?.id)
  }

  @Test func plainTypingNeverResolvesAnIntent() {
    let pane = Self.pane(tabs: [Self.tab()])
    let typing = Self.keyEvent(keyCode: kVK_ANSI_W, modifiers: [])
    #expect(
      PaneWindowShortcut.intent(for: typing, pane: pane, overrides: [:], isWorktreeSelected: true) == nil
    )
  }

  @Test func closeTabChordResolvesToTheSelectedTabsContent() {
    let tab = Self.tab()
    let pane = Self.pane(tabs: [tab])
    let event = Self.keyEvent(keyCode: kVK_ANSI_W, modifiers: .command)
    #expect(
      PaneWindowShortcut.intent(for: event, pane: pane, overrides: [:], isWorktreeSelected: true)
        == .closeTab(tab.content.id)
    )
  }

  @Test func repeatedChordsAreSwallowedNotReapplied() {
    let pane = Self.pane(tabs: [Self.tab()])
    let repeated = Self.keyEvent(keyCode: kVK_ANSI_W, modifiers: .command, isARepeat: true)
    #expect(
      PaneWindowShortcut.intent(for: repeated, pane: pane, overrides: [:], isWorktreeSelected: true)
        == .ignore
    )
  }

  @Test func renameIsSwallowedForATitleLockedTab() {
    let pane = Self.pane(tabs: [Self.tab(isLocked: true)])
    let event = Self.keyEvent(keyCode: kVK_ANSI_R, modifiers: [.control, .shift])
    #expect(
      PaneWindowShortcut.intent(for: event, pane: pane, overrides: [:], isWorktreeSelected: true)
        == .ignore
    )
  }

  @Test func outOfRangeTabChordClampsToTheLastTab() {
    let tabs = [Self.tab(title: "One"), Self.tab(title: "Two"), Self.tab(title: "Three")]
    let pane = Self.pane(tabs: tabs)
    let event = Self.keyEvent(keyCode: kVK_ANSI_9, modifiers: .command)
    #expect(
      PaneWindowShortcut.intent(for: event, pane: pane, overrides: [:], isWorktreeSelected: true)
        == .selectTab(tabs[2].id)
    )
  }

  @Test func tabChordSelectsTheNthTabOfThisPane() {
    let tabs = [Self.tab(title: "One"), Self.tab(title: "Two")]
    let pane = Self.pane(tabs: tabs)
    let event = Self.keyEvent(keyCode: kVK_ANSI_2, modifiers: .command)
    #expect(
      PaneWindowShortcut.intent(for: event, pane: pane, overrides: [:], isWorktreeSelected: true)
        == .selectTab(tabs[1].id)
    )
  }

  @Test func runScriptIsSwallowedWhenThePanesWorktreeIsNotSelected() {
    let pane = Self.pane(tabs: [Self.tab()])
    let event = Self.keyEvent(keyCode: kVK_ANSI_R, modifiers: .command)
    #expect(
      PaneWindowShortcut.intent(for: event, pane: pane, overrides: [:], isWorktreeSelected: false)
        == .ignore
    )
    #expect(
      PaneWindowShortcut.intent(for: event, pane: pane, overrides: [:], isWorktreeSelected: true)
        == .runScript
    )
  }

  @Test func toggleWindowModeResolvesEvenForAnEmptyPane() {
    let pane = Self.pane(tabs: [])
    let event = Self.keyEvent(keyCode: kVK_ANSI_M, modifiers: [.command, .shift])
    #expect(
      PaneWindowShortcut.intent(for: event, pane: pane, overrides: [:], isWorktreeSelected: true)
        == .exitWindowMode
    )
  }

  @Test func disabledShortcutNeverResolves() {
    let pane = Self.pane(tabs: [Self.tab()])
    let event = Self.keyEvent(keyCode: kVK_ANSI_M, modifiers: [.command, .shift])
    #expect(
      PaneWindowShortcut.intent(
        for: event,
        pane: pane,
        overrides: [.toggleWindowMode: .disabled],
        isWorktreeSelected: true
      ) == nil
    )
  }

  @Test func unavailableLayoutChordsAreConsumedNotForwarded() {
    // A split chord leaking to the menu would split the selected worktree's
    // layout while the user is working in a pane window.
    let pane = Self.pane(tabs: [Self.tab()])
    let split = Self.keyEvent(keyCode: kVK_ANSI_D, modifiers: .command)
    #expect(
      PaneWindowShortcut.intent(for: split, pane: pane, overrides: [:], isWorktreeSelected: true)
        == .ignore
    )
    let zoom = Self.keyEvent(keyCode: kVK_Return, modifiers: [.command, .shift])
    #expect(
      PaneWindowShortcut.intent(for: zoom, pane: pane, overrides: [:], isWorktreeSelected: true)
        == .ignore
    )
  }

  @Test func relativeTabCyclingShortcutsUseTabChords() {
    #expect(AppShortcuts.selectNextTab.keyEquivalent.character == "\t")
    #expect(AppShortcuts.selectNextTab.modifiers == [.control])
    #expect(AppShortcuts.selectPreviousTab.keyEquivalent.character == "\t")
    #expect(AppShortcuts.selectPreviousTab.modifiers == [.control, .shift])
  }

  @Test func layoutAndTabSelectionChordsAreUnboundInGhostty() {
    let lines = Set(AppShortcuts.ghosttyKeybindConfigLines(from: [:]))
    // Guards the "topology owned by the app" invariant: a newly added layout or
    // tab-selection shortcut cannot silently leave its chord bound in Ghostty.
    let groups = AppShortcuts.groups.filter { $0.category == .layout || $0.category == .tabSelection }
    for shortcut in groups.flatMap(\.shortcuts) {
      guard let effective = shortcut.effective(from: [:]) else { continue }
      let keybind = effective.ghosttyKeybind
      guard !keybind.contains("0x") else { continue }
      #expect(lines.contains("keybind = \(keybind)=unbind"), "\(shortcut.displayName) not unbound")
    }
  }
}
