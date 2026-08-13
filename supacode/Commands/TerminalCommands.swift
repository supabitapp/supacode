import ComposableArchitecture
import Sharing
import SupacodeSettingsShared
import SwiftUI

struct TerminalCommands: Commands {
  let ghosttyShortcuts: GhosttyShortcutManager
  @Shared(.settingsFile) private var settingsFile
  @FocusedValue(\.newTerminalAction) private var newTerminalAction
  @FocusedValue(\.renameTabAction) private var renameTabAction
  @FocusedValue(\.splitTerminalAction) private var splitTerminalAction
  @FocusedValue(\.toggleWindowModeAction) private var toggleWindowModeAction
  @FocusedValue(\.toggleSplitZoomAction) private var toggleSplitZoomAction
  @FocusedValue(\.equalizeSplitsAction) private var equalizeSplitsAction
  @FocusedValue(\.focusSplitAction) private var focusSplitAction
  @FocusedValue(\.startSearchAction) private var startSearchAction
  @FocusedValue(\.searchSelectionAction) private var searchSelectionAction
  @FocusedValue(\.navigateSearchNextAction) private var navigateSearchNextAction
  @FocusedValue(\.navigateSearchPreviousAction) private var navigateSearchPreviousAction
  @FocusedValue(\.endSearchAction) private var endSearchAction

  var body: some Commands {
    let overrides = settingsFile.global.shortcutOverrides
    let renameTab = AppShortcuts.renameTab.effective(from: overrides)
    let toggleWindowMode = AppShortcuts.toggleWindowMode.effective(from: overrides)
    CommandGroup(after: .newItem) {
      Divider()
      Button("New Terminal Tab", systemImage: "macwindow") {
        newTerminalAction?()
      }
      .appKeyboardShortcut(AppShortcuts.newTerminalTab.effective(from: overrides))
      .disabled(newTerminalAction?.isEnabled != true)

      Button("Rename Tab", systemImage: "pencil") {
        renameTabAction?()
      }
      .appKeyboardShortcut(renameTab)
      .disabled(renameTabAction?.isEnabled != true)
      .help("Rename Tab (\(renameTab?.display ?? "none"))")

      Divider()

      ForEach(TerminalSplitMenuDirection.allCases, id: \.self) { direction in
        Button(direction.menuBarTitle, systemImage: direction.systemImage) {
          splitTerminalAction?(direction)
        }
        .appKeyboardShortcut(direction.appShortcut.effective(from: overrides))
        .disabled(splitTerminalAction?.isEnabled != true)
      }

      Divider()

      ForEach(TerminalSplitMenuDirection.allCases, id: \.self) { direction in
        Button(direction.focusMenuBarTitle, systemImage: direction.systemImage) {
          focusSplitAction?(direction)
        }
        .appKeyboardShortcut(direction.focusAppShortcut.effective(from: overrides))
        .disabled(focusSplitAction?.isEnabled != true)
      }

      Button("Toggle Split Zoom", systemImage: "arrow.up.left.and.arrow.down.right") {
        toggleSplitZoomAction?()
      }
      .appKeyboardShortcut(AppShortcuts.toggleSplitZoom.effective(from: overrides))
      .disabled(toggleSplitZoomAction?.isEnabled != true)

      Button("Equalize Splits", systemImage: "rectangle.split.2x1") {
        equalizeSplitsAction?()
      }
      .appKeyboardShortcut(AppShortcuts.equalizeSplits.effective(from: overrides))
      .disabled(equalizeSplitsAction?.isEnabled != true)

      Divider()

      Button("Toggle Window Mode", systemImage: "macwindow.on.rectangle") {
        toggleWindowModeAction?()
      }
      .appKeyboardShortcut(toggleWindowMode)
      .disabled(toggleWindowModeAction?.isEnabled != true)
      .help("Toggle Window Mode (\(toggleWindowMode?.display ?? "none"))")
    }
    CommandGroup(after: .textEditing) {
      Button("Find...") {
        startSearchAction?()
      }
      .ghosttyKeyboardShortcut("start_search", in: ghosttyShortcuts)
      .disabled(startSearchAction?.isEnabled != true)

      Button("Find Next") {
        navigateSearchNextAction?()
      }
      .ghosttyKeyboardShortcut("navigate_search:next", in: ghosttyShortcuts)
      .disabled(navigateSearchNextAction?.isEnabled != true)

      Button("Find Previous") {
        navigateSearchPreviousAction?()
      }
      .ghosttyKeyboardShortcut("navigate_search:previous", in: ghosttyShortcuts)
      .disabled(navigateSearchPreviousAction?.isEnabled != true)

      Divider()

      Button("Hide Find Bar") {
        endSearchAction?()
      }
      .ghosttyKeyboardShortcut("end_search", in: ghosttyShortcuts)
      .disabled(endSearchAction?.isEnabled != true)

      Divider()

      Button("Use Selection for Find") {
        searchSelectionAction?()
      }
      .ghosttyKeyboardShortcut("search_selection", in: ghosttyShortcuts)
      .disabled(searchSelectionAction?.isEnabled != true)
    }
  }
}

/// Static ⌘1..⌘9 submenu switching the selected worktree's terminal tab. Uses
/// the store (not a `FocusedAction`) so the menu key-equivalent fires regardless
/// of which pane holds first responder; out-of-range tabs clamp in the reducer.
struct TerminalTabSelectionCommands: Commands {
  @Bindable var store: StoreOf<AppFeature>
  @Shared(.settingsFile) private var settingsFile

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Menu("Select Tab") {
        TerminalTabSelectionItems(store: store, overrides: settingsFile.global.shortcutOverrides)
      }
    }
  }
}

private struct TerminalTabSelectionItems: View {
  let store: StoreOf<AppFeature>
  let overrides: [AppShortcutID: AppShortcutOverride]

  var body: some View {
    ForEach(0..<AppShortcuts.tabSelection.count, id: \.self) { index in
      let shortcut = AppShortcuts.tabSelection[index].effective(from: overrides)
      Button("Select Tab \(index + 1)") {
        store.send(.selectTerminalTabAtIndex(index + 1))
      }
      .appKeyboardShortcut(shortcut)
      .help("Select Tab \(index + 1) (\(shortcut?.display ?? "no shortcut"))")
    }
    Divider()
    RelativeTabSelectionButton(
      title: "Select Previous Tab", shortcut: AppShortcuts.selectPreviousTab, overrides: overrides
    ) {
      store.send(.selectPreviousTerminalTab)
    }
    RelativeTabSelectionButton(
      title: "Select Next Tab", shortcut: AppShortcuts.selectNextTab, overrides: overrides
    ) {
      store.send(.selectNextTerminalTab)
    }
  }
}

private struct RelativeTabSelectionButton: View {
  let title: String
  let shortcut: AppShortcut
  let overrides: [AppShortcutID: AppShortcutOverride]
  let action: () -> Void

  var body: some View {
    let effective = shortcut.effective(from: overrides)
    Button(title) {
      // Holding the chord would otherwise cycle past the intended tab.
      guard NSApp.currentEvent?.isAutoRepeatKeyDown != true else { return }
      action()
    }
    .appKeyboardShortcut(effective)
    .help("\(title) (\(effective?.display ?? "no shortcut"))")
  }
}

private struct NewTerminalActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

extension FocusedValues {
  var newTerminalAction: FocusedAction<Void>? {
    get { self[NewTerminalActionKey.self] }
    set { self[NewTerminalActionKey.self] = newValue }
  }
}

private struct ToggleWindowModeActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

private struct ToggleSplitZoomActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

private struct EqualizeSplitsActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

private struct FocusSplitActionKey: FocusedValueKey {
  typealias Value = FocusedAction<TerminalSplitMenuDirection>
}

private struct RenameTabActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

extension FocusedValues {
  var toggleWindowModeAction: FocusedAction<Void>? {
    get { self[ToggleWindowModeActionKey.self] }
    set { self[ToggleWindowModeActionKey.self] = newValue }
  }

  var toggleSplitZoomAction: FocusedAction<Void>? {
    get { self[ToggleSplitZoomActionKey.self] }
    set { self[ToggleSplitZoomActionKey.self] = newValue }
  }

  var equalizeSplitsAction: FocusedAction<Void>? {
    get { self[EqualizeSplitsActionKey.self] }
    set { self[EqualizeSplitsActionKey.self] = newValue }
  }

  var focusSplitAction: FocusedAction<TerminalSplitMenuDirection>? {
    get { self[FocusSplitActionKey.self] }
    set { self[FocusSplitActionKey.self] = newValue }
  }

  var renameTabAction: FocusedAction<Void>? {
    get { self[RenameTabActionKey.self] }
    set { self[RenameTabActionKey.self] = newValue }
  }
}

private struct SplitTerminalActionKey: FocusedValueKey {
  typealias Value = FocusedAction<TerminalSplitMenuDirection>
}

extension FocusedValues {
  var splitTerminalAction: FocusedAction<TerminalSplitMenuDirection>? {
    get { self[SplitTerminalActionKey.self] }
    set { self[SplitTerminalActionKey.self] = newValue }
  }
}

private struct CloseSurfaceActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

extension FocusedValues {
  var closeSurfaceAction: FocusedAction<Void>? {
    get { self[CloseSurfaceActionKey.self] }
    set { self[CloseSurfaceActionKey.self] = newValue }
  }
}

private struct CloseTabActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

extension FocusedValues {
  var closeTabAction: FocusedAction<Void>? {
    get { self[CloseTabActionKey.self] }
    set { self[CloseTabActionKey.self] = newValue }
  }
}

private struct StartSearchActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

extension FocusedValues {
  var startSearchAction: FocusedAction<Void>? {
    get { self[StartSearchActionKey.self] }
    set { self[StartSearchActionKey.self] = newValue }
  }
}

private struct SearchSelectionActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

extension FocusedValues {
  var searchSelectionAction: FocusedAction<Void>? {
    get { self[SearchSelectionActionKey.self] }
    set { self[SearchSelectionActionKey.self] = newValue }
  }
}

private struct NavigateSearchNextActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

extension FocusedValues {
  var navigateSearchNextAction: FocusedAction<Void>? {
    get { self[NavigateSearchNextActionKey.self] }
    set { self[NavigateSearchNextActionKey.self] = newValue }
  }
}

private struct NavigateSearchPreviousActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

extension FocusedValues {
  var navigateSearchPreviousAction: FocusedAction<Void>? {
    get { self[NavigateSearchPreviousActionKey.self] }
    set { self[NavigateSearchPreviousActionKey.self] = newValue }
  }
}

private struct EndSearchActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

extension FocusedValues {
  var endSearchAction: FocusedAction<Void>? {
    get { self[EndSearchActionKey.self] }
    set { self[EndSearchActionKey.self] = newValue }
  }
}
