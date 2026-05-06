import SwiftUI

extension View {
  func terminalTabContextMenu(
    tabId: TerminalTabID,
    tabs: [TerminalTabItem],
    actions: TerminalTabContextMenuActions
  ) -> some View {
    modifier(
      TerminalTabContextMenu(
        tabId: tabId,
        tabs: tabs,
        actions: actions
      )
    )
  }
}

struct TerminalTabContextMenu: ViewModifier {
  let tabId: TerminalTabID
  let tabs: [TerminalTabItem]
  let actions: TerminalTabContextMenuActions

  func body(content: Content) -> some View {
    content.contextMenu {
      Group {
        if let currentTab, !currentTab.isTitleLocked {
          Button("Rename Tab") {
            actions.renameTab(tabId)
          }
          Divider()
        }

        Button("Close Tab") {
          actions.closeTab(tabId)
        }

        Button("Close Other Tabs") {
          actions.closeOthers(tabId)
        }
        .disabled(tabs.count <= 1)

        Button("Close Tabs to the Right") {
          actions.closeToRight(tabId)
        }
        .disabled(isLastTab)

        Button("Close All") {
          actions.closeAll()
        }
      }
      // SwiftUI menu items containing Labels/Images receive `\.colorScheme`
      // from the surrounding env, so without escaping the chrome override
      // their tinting renders against the wrong appearance.
      .inheritSystemColorScheme()
    }
  }

  private var currentTab: TerminalTabItem? {
    tabs.first { $0.id == tabId }
  }

  private var isLastTab: Bool {
    guard let last = tabs.last else { return true }
    return last.id == tabId
  }
}
