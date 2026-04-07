import AppKit
import SwiftUI

struct WorktreeTerminalTabsView: View {
  enum FocusTarget: Equatable {
    case hoveredSurface(UUID)
    case selectedTab
    case none
  }

  let worktree: Worktree
  let manager: WorktreeTerminalManager
  let shouldRunSetupScript: Bool
  let forceAutoFocus: Bool
  let createTab: () -> Void
  @State private var windowActivity = WindowActivityState.inactive

  var body: some View {
    let state = manager.state(for: worktree) { shouldRunSetupScript }
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
          }
        )
        .transition(.move(edge: .top).combined(with: .opacity))
      }
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
    .animation(.easeInOut(duration: 0.2), value: state.shouldHideTabBar)
    .background(
      WindowFocusObserverView { activity in
        windowActivity = activity
        state.syncFocus(windowIsKey: activity.isKeyWindow, windowIsVisible: activity.isVisible)
      }
    )
    .onAppear {
      state.ensureInitialTab(focusing: false)
      applyKeyboardFocus(for: state)
      let activity = resolvedWindowActivity
      state.syncFocus(windowIsKey: activity.isKeyWindow, windowIsVisible: activity.isVisible)
    }
    .onChange(of: state.tabManager.selectedTabId) { _, _ in
      applyKeyboardFocus(for: state)
      let activity = resolvedWindowActivity
      state.syncFocus(windowIsKey: activity.isKeyWindow, windowIsVisible: activity.isVisible)
    }
  }

  private func applyKeyboardFocus(for state: WorktreeTerminalState) {
    apply(focusTarget(for: state), to: state)

    guard state.focusFollowsMouseEnabled else { return }
    Task { @MainActor in
      await Task.yield()
      guard state.isSelected() else { return }
      if case .hoveredSurface(let surfaceID) = focusTarget(for: state) {
        _ = state.focusSurface(id: surfaceID)
      }
    }
  }

  private func apply(_ focusTarget: FocusTarget, to state: WorktreeTerminalState) {
    switch focusTarget {
    case .hoveredSurface(let surfaceID):
      _ = state.focusSurface(id: surfaceID)
    case .selectedTab:
      state.focusSelectedTab()
    case .none:
      break
    }
  }

  private func focusTarget(for state: WorktreeTerminalState) -> FocusTarget {
    Self.focusTarget(
      forceAutoFocus: forceAutoFocus,
      responder: NSApp.keyWindow?.firstResponder,
      ownedSurfaceIDs: state.surfaceIDs,
      focusFollowsMouseEnabled: state.focusFollowsMouseEnabled,
      hoveredSurfaceID: state.visibleSurfaceIDUnderMouse
    )
  }

  static func focusTarget(
    forceAutoFocus: Bool,
    responder: NSResponder?,
    ownedSurfaceIDs: Set<UUID>,
    focusFollowsMouseEnabled: Bool,
    hoveredSurfaceID: UUID?
  ) -> FocusTarget {
    if focusFollowsMouseEnabled, let hoveredSurfaceID {
      return .hoveredSurface(hoveredSurfaceID)
    }
    if forceAutoFocus {
      return .selectedTab
    }
    guard let responder else { return .selectedTab }
    if responder is NSTableView || responder is NSOutlineView {
      return .none
    }
    guard let surface = responder as? GhosttySurfaceView else {
      return .selectedTab
    }
    return ownedSurfaceIDs.contains(surface.id) ? .selectedTab : .none
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
