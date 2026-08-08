import AppKit
import ComposableArchitecture
import SwiftUI

/// One worktree's terminal area on the layout engine: the pane tree with its
/// close-confirmation alert, window-activity sync, and terminal auto-focus.
struct WorktreeLayoutView: View {
  let worktree: Worktree
  let manager: WorktreeTerminalManager
  let terminalsStore: StoreOf<TerminalsFeature>
  let runtime: ContentRuntime
  let forceAutoFocus: Bool
  @State private var windowActivity = WindowActivityState.inactive
  @State private var windowActivityReader = WindowActivityReader()

  var body: some View {
    // Re-read config-derived colors on every Ghostty config reload.
    let _ = manager.configGeneration
    let selectedContentID = selectedContentID
    Group {
      if let layoutStore = terminalsStore.scope(
        state: \.layouts[id: worktree.id],
        action: \.layouts[id: worktree.id]
      ) {
        LayoutAlertHost(
          store: layoutStore,
          runtime: runtime,
          dividerColor: manager.splitDividerColor()
        )
      } else {
        EmptyTerminalPaneView(message: "No terminals open")
      }
    }
    .background(
      WindowFocusObserverView(reader: windowActivityReader) { activity in
        windowActivity = activity
        host?.syncFocus(windowIsKey: activity.isKeyWindow, windowIsVisible: activity.isVisible)
      }
    )
    .onAppear {
      if shouldAutoFocusTerminal {
        host?.focusSelectedTab()
      }
      syncResolvedWindowActivity()
    }
    .onChange(of: selectedContentID) {
      if shouldAutoFocusTerminal {
        host?.focusSelectedTab()
      }
      syncResolvedWindowActivity()
    }
  }

  private var host: WorktreeContentHost? {
    manager.hostIfExists(for: worktree.id)
  }

  /// The focused pane's selected content; drives the auto-focus handoff when
  /// selection moves (Cmd+T, tab click, deeplink jump).
  private var selectedContentID: UUID? {
    guard let layout = terminalsStore.layouts[id: worktree.id]?.layout,
      let focused = layout.focusedPaneID
    else { return nil }
    return layout.panes[id: focused]?.selectedTab?.content.id.rawValue
  }

  private var shouldAutoFocusTerminal: Bool {
    if forceAutoFocus {
      return true
    }
    guard let responder = NSApp.keyWindow?.firstResponder else { return true }
    return !(responder is NSTableView) && !(responder is NSOutlineView)
  }

  private func syncResolvedWindowActivity() {
    // The observed window is authoritative; `NSApp.keyWindow` can be another
    // window entirely (e.g. the command palette panel).
    let activity = windowActivityReader.current ?? windowActivity
    host?.syncFocus(windowIsKey: activity.isKeyWindow, windowIsVisible: activity.isVisible)
  }
}

/// Hosts the pane tree and binds the layout's close-confirmation alert.
private struct LayoutAlertHost: View {
  @Bindable var store: StoreOf<LayoutFeature>
  let runtime: ContentRuntime
  let dividerColor: Color

  var body: some View {
    LayoutContentView(store: store, runtime: runtime, dividerColor: dividerColor)
      .alert($store.scope(state: \.alert, action: \.alert))
  }
}
