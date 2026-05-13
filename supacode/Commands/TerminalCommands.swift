import SwiftUI

struct TerminalCommands: Commands {
  let ghosttyShortcuts: GhosttyShortcutManager
  @FocusedValue(\.newTerminalAction) private var newTerminalAction
  @FocusedValue(\.splitTerminalAction) private var splitTerminalAction
  @FocusedValue(\.startSearchAction) private var startSearchAction
  @FocusedValue(\.searchSelectionAction) private var searchSelectionAction
  @FocusedValue(\.navigateSearchNextAction) private var navigateSearchNextAction
  @FocusedValue(\.navigateSearchPreviousAction) private var navigateSearchPreviousAction
  @FocusedValue(\.endSearchAction) private var endSearchAction

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Divider()
      Button("New Terminal Tab", systemImage: "macwindow") {
        newTerminalAction?()
      }
      .ghosttyKeyboardShortcut("new_tab", in: ghosttyShortcuts)
      .disabled(newTerminalAction == nil)

      Divider()

      ForEach(TerminalSplitMenuDirection.allCases, id: \.self) { direction in
        Button(direction.menuBarTitle, systemImage: direction.systemImage) {
          splitTerminalAction?(direction)
        }
        .ghosttyKeyboardShortcut(direction.ghosttyBinding, in: ghosttyShortcuts)
        .disabled(splitTerminalAction == nil)
      }
    }
    CommandGroup(after: .textEditing) {
      Button("Find...") {
        startSearchAction?()
      }
      .ghosttyKeyboardShortcut("start_search", in: ghosttyShortcuts)
      .disabled(startSearchAction == nil)

      Button("Find Next") {
        navigateSearchNextAction?()
      }
      .ghosttyKeyboardShortcut("navigate_search:next", in: ghosttyShortcuts)
      .disabled(navigateSearchNextAction == nil)

      Button("Find Previous") {
        navigateSearchPreviousAction?()
      }
      .ghosttyKeyboardShortcut("navigate_search:previous", in: ghosttyShortcuts)
      .disabled(navigateSearchPreviousAction == nil)

      Divider()

      Button("Hide Find Bar") {
        endSearchAction?()
      }
      .ghosttyKeyboardShortcut("end_search", in: ghosttyShortcuts)
      .disabled(endSearchAction == nil)

      Divider()

      Button("Use Selection for Find") {
        searchSelectionAction?()
      }
      .ghosttyKeyboardShortcut("search_selection", in: ghosttyShortcuts)
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

private struct SplitTerminalActionKey: FocusedValueKey {
  typealias Value = (TerminalSplitMenuDirection) -> Void
}

extension FocusedValues {
  var splitTerminalAction: ((TerminalSplitMenuDirection) -> Void)? {
    get { self[SplitTerminalActionKey.self] }
    set { self[SplitTerminalActionKey.self] = newValue }
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
