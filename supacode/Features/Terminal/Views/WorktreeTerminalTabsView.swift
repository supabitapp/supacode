import AppKit
import SwiftUI

struct WorktreeTerminalTabsView: View {
  let worktree: Worktree
  let manager: WorktreeTerminalManager
  let shouldRunSetupScript: Bool
  let forceAutoFocus: Bool
  let createTab: () -> Void
  @State private var windowActivity = WindowActivityState.inactive
  // SwiftUI invalidation token. Runtime config values aren't Observable, so
  // we bump this counter on `.ghosttyRuntimeConfigDidChange` to force body
  // to re-read `manager.unfocusedSplitOverlay()` after a live reload.
  @State private var configReloadCounter = 0

  var body: some View {
    let state = manager.state(for: worktree) { shouldRunSetupScript }
    let _ = configReloadCounter
    let unfocusedSplitOverlay = manager.unfocusedSplitOverlay()
    VStack(spacing: 0) {
      if !state.shouldHideTabBar {
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
          },
          hasNotification: { tabId in
            state.hasUnseenNotification(forTabID: tabId)
          }
        )
        .transition(.move(edge: .top).combined(with: .opacity))
      }
      if let selectedId = state.tabManager.selectedTabId {
        TerminalTabContentStack(tabs: state.tabManager.tabs, selectedTabId: selectedId) { tabId in
          TerminalSplitTreeAXContainer(
            tree: state.splitTree(for: tabId),
            activeSurfaceID: state.activeSurfaceID(for: tabId),
            unfocusedSplitOverlay: unfocusedSplitOverlay,
            hasNotification: { surfaceID in
              state.hasUnseenNotification(forSurfaceID: surfaceID)
            },
            action: { operation in
              state.performSplitOperation(operation, in: tabId)
            }
          )
        }
      } else {
        EmptyTerminalPaneView(message: "No terminals open")
      }
    }
    .animation(.easeInOut(duration: 0.2), value: state.shouldHideTabBar)
    .background(
      WindowFocusObserverView { activity in
        windowActivity = activity
        state.syncFocus(windowIsKey: activity.isKeyWindow, windowIsVisible: activity.isVisible)
      }
    )
    .onAppear {
      state.ensureInitialTab(focusing: false)
      if shouldAutoFocusTerminal {
        state.focusSelectedTab()
      }
      let activity = resolvedWindowActivity
      state.syncFocus(windowIsKey: activity.isKeyWindow, windowIsVisible: activity.isVisible)
    }
    .onChange(of: state.tabManager.selectedTabId) { _, _ in
      if shouldAutoFocusTerminal {
        state.focusSelectedTab()
      }
      let activity = resolvedWindowActivity
      state.syncFocus(windowIsKey: activity.isKeyWindow, windowIsVisible: activity.isVisible)
    }
    .onReceive(NotificationCenter.default.publisher(for: .ghosttyRuntimeConfigDidChange)) { _ in
      configReloadCounter &+= 1
    }
  }

  private var shouldAutoFocusTerminal: Bool {
    if forceAutoFocus {
      return true
    }
    guard let responder = NSApp.keyWindow?.firstResponder else { return true }
    return !(responder is NSTableView) && !(responder is NSOutlineView)
  }

  private var resolvedWindowActivity: WindowActivityState {
    if let keyWindow = NSApp.keyWindow {
      return WindowActivityState(
        isKeyWindow: keyWindow.isKeyWindow,
        isVisible: keyWindow.occlusionState.contains(.visible)
      )
    }
    return windowActivity
  }
}
