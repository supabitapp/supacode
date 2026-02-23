import Sharing
import SwiftUI

struct TerminalCommands: Commands {
  let ghosttyShortcuts: GhosttyShortcutManager
  @FocusedValue(\.newTerminalAction) private var newTerminalAction
  @FocusedValue(\.closeSurfaceAction) private var closeSurfaceAction
  @FocusedValue(\.closeTabAction) private var closeTabAction
  @FocusedValue(\.startSearchAction) private var startSearchAction
  @FocusedValue(\.searchSelectionAction) private var searchSelectionAction
  @FocusedValue(\.navigateSearchNextAction) private var navigateSearchNextAction
  @FocusedValue(\.navigateSearchPreviousAction) private var navigateSearchPreviousAction
  @FocusedValue(\.endSearchAction) private var endSearchAction
  @Shared(.settingsFile) private var settingsFile

  var body: some Commands {
    let globalSettings = settingsFile.global
    let findShortcut = AppShortcuts.find.effective(from: globalSettings)
    let findNextShortcut = AppShortcuts.findNext.effective(from: globalSettings)
    let findPrevShortcut = AppShortcuts.findPrevious.effective(from: globalSettings)
    let hideFindShortcut = AppShortcuts.hideFindBar.effective(from: globalSettings)
    let useSelectionShortcut = AppShortcuts.useSelectionForFind.effective(from: globalSettings)
    CommandGroup(after: .newItem) {
      Button("New Terminal") {
        newTerminalAction?()
      }
      .modifier(KeyboardShortcutModifier(shortcut: ghosttyShortcuts.keyboardShortcut(for: "new_tab")))
      .disabled(newTerminalAction == nil)
      Button("Close") {
        closeSurfaceAction?()
      }
      .modifier(
        KeyboardShortcutModifier(shortcut: ghosttyShortcuts.keyboardShortcut(for: "close_surface"))
      )
      .disabled(closeSurfaceAction == nil)
      Button("Close Tab") {
        closeTabAction?()
      }
      .modifier(
        KeyboardShortcutModifier(shortcut: ghosttyShortcuts.keyboardShortcut(for: "close_tab"))
      )
      .disabled(closeTabAction == nil)
    }
    CommandGroup(after: .textEditing) {
      Button("Find...") {
        startSearchAction?()
      }
      .keyboardShortcut(findShortcut.keyEquivalent, modifiers: findShortcut.modifiers)
      .help("Find (\(findShortcut.display))")
      .disabled(startSearchAction == nil)

      Button("Find Next") {
        navigateSearchNextAction?()
      }
      .keyboardShortcut(findNextShortcut.keyEquivalent, modifiers: findNextShortcut.modifiers)
      .help("Find Next (\(findNextShortcut.display))")
      .disabled(navigateSearchNextAction == nil)

      Button("Find Previous") {
        navigateSearchPreviousAction?()
      }
      .keyboardShortcut(findPrevShortcut.keyEquivalent, modifiers: findPrevShortcut.modifiers)
      .help("Find Previous (\(findPrevShortcut.display))")
      .disabled(navigateSearchPreviousAction == nil)

      Divider()

      Button("Hide Find Bar") {
        endSearchAction?()
      }
      .keyboardShortcut(hideFindShortcut.keyEquivalent, modifiers: hideFindShortcut.modifiers)
      .help("Hide Find Bar (\(hideFindShortcut.display))")
      .disabled(endSearchAction == nil)

      Divider()

      Button("Use Selection for Find") {
        searchSelectionAction?()
      }
      .keyboardShortcut(useSelectionShortcut.keyEquivalent, modifiers: useSelectionShortcut.modifiers)
      .help("Use Selection for Find (\(useSelectionShortcut.display))")
      .disabled(searchSelectionAction == nil)
    }
  }
}

private struct NewTerminalActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

extension FocusedValues {
  var newTerminalAction: (() -> Void)? {
    get { self[NewTerminalActionKey.self] }
    set { self[NewTerminalActionKey.self] = newValue }
  }
}

private struct CloseSurfaceActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

extension FocusedValues {
  var closeSurfaceAction: (() -> Void)? {
    get { self[CloseSurfaceActionKey.self] }
    set { self[CloseSurfaceActionKey.self] = newValue }
  }
}

private struct CloseTabActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

extension FocusedValues {
  var closeTabAction: (() -> Void)? {
    get { self[CloseTabActionKey.self] }
    set { self[CloseTabActionKey.self] = newValue }
  }
}

private struct StartSearchActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

extension FocusedValues {
  var startSearchAction: (() -> Void)? {
    get { self[StartSearchActionKey.self] }
    set { self[StartSearchActionKey.self] = newValue }
  }
}

private struct SearchSelectionActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

extension FocusedValues {
  var searchSelectionAction: (() -> Void)? {
    get { self[SearchSelectionActionKey.self] }
    set { self[SearchSelectionActionKey.self] = newValue }
  }
}

private struct NavigateSearchNextActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

extension FocusedValues {
  var navigateSearchNextAction: (() -> Void)? {
    get { self[NavigateSearchNextActionKey.self] }
    set { self[NavigateSearchNextActionKey.self] = newValue }
  }
}

private struct NavigateSearchPreviousActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

extension FocusedValues {
  var navigateSearchPreviousAction: (() -> Void)? {
    get { self[NavigateSearchPreviousActionKey.self] }
    set { self[NavigateSearchPreviousActionKey.self] = newValue }
  }
}

private struct EndSearchActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

extension FocusedValues {
  var endSearchAction: (() -> Void)? {
    get { self[EndSearchActionKey.self] }
    set { self[EndSearchActionKey.self] = newValue }
  }
}

private struct KeyboardShortcutModifier: ViewModifier {
  let shortcut: KeyboardShortcut?

  func body(content: Content) -> some View {
    if let shortcut {
      content.keyboardShortcut(shortcut)
    } else {
      content
    }
  }
}
