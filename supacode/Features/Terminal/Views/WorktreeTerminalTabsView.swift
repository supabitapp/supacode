import AppKit
import SwiftUI

struct WorktreeTerminalTabsView: View {
  let worktree: Worktree
  let manager: WorktreeTerminalManager
  let shouldRunSetupScript: Bool
  let forceAutoFocus: Bool
  let createTab: () -> Void

  var body: some View {
    let state = manager.state(for: worktree) { shouldRunSetupScript }
    VStack(spacing: 0) {
      TerminalTabBarView(
        manager: state.tabManager,
        createTab: createTab,
        splitHorizontally: {
          _ = state.performBindingActionOnFocusedSurface("new_split:down")
        },
        splitVertically: {
          _ = state.performBindingActionOnFocusedSurface("new_split:right")
        },
        canSplit: state.tabManager.selectedTabId != nil,
        closeTab: { tabId in
          state.closeTab(tabId)
        },
        closeOthers: { tabId in
          state.closeOtherTabs(keeping: tabId)
        },
        closeToRight: { tabId in
          state.closeTabsToRight(of: tabId)
        },
        closeAll: {
          state.closeAllTabs()
        }
      )
      if let selectedId = state.tabManager.selectedTabId {
        TerminalTabContentStack(tabs: state.tabManager.tabs, selectedTabId: selectedId) { tabId in
          TerminalSplitTreeAXContainer(tree: state.splitTree(for: tabId)) { operation in
            state.performSplitOperation(operation, in: tabId)
          }
        }
      } else {
        EmptyTerminalPaneView(message: "No terminals open")
      }
    }
    .background(
      WindowFocusObserverView { isKey in
        state.syncFocus(windowIsKey: isKey)
      }
    )
    .onAppear {
      state.ensureInitialTab(focusing: false)
      if shouldAutoFocusTerminal {
        state.focusSelectedTab()
      }
    }
    .onChange(of: state.tabManager.selectedTabId) { _, _ in
      if shouldAutoFocusTerminal {
        state.focusSelectedTab()
      }
      state.syncFocus(windowIsKey: NSApp.keyWindow?.isKeyWindow ?? false)
    }
  }

  private var shouldAutoFocusTerminal: Bool {
    if forceAutoFocus {
      return true
    }
    guard let responder = NSApp.keyWindow?.firstResponder else { return true }
    return !(responder is NSTableView) && !(responder is NSOutlineView)
  }
}
