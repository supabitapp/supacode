import AppKit
import ComposableArchitecture
import SwiftUI

struct WorktreeTerminalTabsView: View {
  let worktree: Worktree
  let manager: WorktreeTerminalManager
  /// Narrowed terminal-orchestration store. The tab bar scopes per-tab
  /// `TerminalTabFeature` stores via `\.terminalTabs[id:]` from here, so the
  /// tab-bar surface area stays bounded to terminal state.
  let terminalsStore: StoreOf<TerminalsFeature>
  let shouldRunSetupScript: Bool
  let forceAutoFocus: Bool
  let createTab: () -> Void
  @State private var windowActivity = WindowActivityState.inactive
  // Reading `\.colorScheme` invalidates this body when the window appearance
  // flips (terminal-driven Light/Dark), so the unfocused-split overlay retints.
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let state = manager.state(for: worktree) { shouldRunSetupScript }
    // Must precede the body's tab-state read. Deferring to `.task` / `.onAppear`
    // would reintroduce the closed-all flash on first render.
    let _: Void = state.ensureInitialTab(focusing: false)
    // Re-read config-derived colors on every Ghostty config reload, even when
    // the focused background is unchanged (e.g. only `split-divider-color` moved).
    let _ = manager.configGeneration
    let unfocusedSplitOverlay = manager.unfocusedSplitOverlay()
    let dividerColor = manager.splitDividerColor()
    let _ = colorScheme
    VStack(spacing: 0) {
      if !state.shouldHideTabBar {
        TerminalTabBarView(
          manager: state.tabManager,
          terminalState: state,
          terminalsStore: terminalsStore,
          createTab: createTab,
          split: { direction in
            _ = state.performBindingActionOnFocusedSurface(direction.ghosttyBinding)
          },
          canSplit: state.tabManager.selectedTabId.flatMap { state.activeSurfaceID(for: $0) } != nil,
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
          dismissSplitZoom: { tabId in
            state.dismissSplitZoom(for: tabId)
          },
          renameTab: { tabId, newTitle in
            state.renameTab(tabId, title: newTitle)
          },
        )
        .transition(.move(edge: .top).combined(with: .opacity))
      }
      if let selectedId = state.tabManager.selectedTabId {
        TerminalTabContentStack(tabs: state.tabManager.tabs, selectedTabId: selectedId) { tabId in
          TerminalSplitTreePane(
            tabId: tabId,
            terminalState: state,
            terminalsStore: terminalsStore,
            unfocusedSplitOverlay: unfocusedSplitOverlay,
            dividerColor: dividerColor
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

/// Reads the per-tab projection so SwiftUI invalidates whenever the tab's surface
/// set or focus changes. `WorktreeTerminalState.trees` and `focusedSurfaceIdByTab`
/// are `@ObservationIgnored`, so without this dependency Cmd+D / Cmd+W would not
/// re-render until something else (a worktree switch) forced a body recompute.
private struct TerminalSplitTreePane: View {
  let tabId: TerminalTabID
  let terminalState: WorktreeTerminalState
  let terminalsStore: StoreOf<TerminalsFeature>
  let unfocusedSplitOverlay: (fill: Color?, opacity: Double)
  let dividerColor: Color

  var body: some View {
    let projection = terminalsStore.terminalTabs[id: tabId]
    let _ = projection?.surfaceIDs
    let _ = projection?.activeSurfaceID
    // Touch generation so SwiftUI rebuilds the tree when a same-UUID surface view is swapped under it.
    let _ = projection?.surfaceGeneration
    TerminalSplitTreeAXContainer(
      tree: terminalState.splitTree(for: tabId),
      terminalState: terminalState,
      activeSurfaceID: terminalState.activeSurfaceID(for: tabId),
      unfocusedSplitOverlay: unfocusedSplitOverlay,
      dividerColor: dividerColor,
      action: { operation in
        terminalState.performSplitOperation(operation, in: tabId)
      }
    )
  }
}
