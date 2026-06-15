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
      .disabled(newTerminalAction?.isEnabled != true)

      Divider()

      ForEach(TerminalSplitMenuDirection.allCases, id: \.self) { direction in
        Button(direction.menuBarTitle, systemImage: direction.systemImage) {
          splitTerminalAction?(direction)
        }
        .ghosttyKeyboardShortcut(direction.ghosttyBinding, in: ghosttyShortcuts)
        .disabled(splitTerminalAction?.isEnabled != true)
      }
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

private struct NewTerminalActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

extension FocusedValues {
  var newTerminalAction: FocusedAction<Void>? {
    get { self[NewTerminalActionKey.self] }
    set { self[NewTerminalActionKey.self] = newValue }
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
