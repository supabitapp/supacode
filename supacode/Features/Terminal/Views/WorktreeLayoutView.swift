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
  var isLifecycleBusy = false
  @State private var windowActivity = WindowActivityState.inactive
  @State private var windowActivityReader = WindowActivityReader()
  // Reading `\.colorScheme` invalidates this body when the window appearance
  // flips (terminal-driven Light/Dark), so the unfocused-split overlay retints.
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    // Re-read config-derived colors on every Ghostty config reload.
    let _ = manager.configGeneration
    let _ = colorScheme
    let selectedContentID = selectedContentID
    Group {
      // An empty layout must not mount the AX container: it cuts the window
      // tint's mask hole, and with no surface to paint the hole shows raw
      // window blur instead of the terminal background.
      if let layoutStore = terminalsStore.scope(
        state: \.layouts[id: worktree.id],
        action: \.layouts[id: worktree.id]
      ), !layoutStore.layout.panes.isEmpty {
        LayoutAlertHost(
          store: layoutStore,
          runtime: runtime,
          dividerColor: manager.splitDividerColor(),
          // The strip sits inside the tint-mask hole; repaint the chrome tint
          // behind it or transparent windows show raw blur above every pane.
          // `focusedSurfaceBackground` is observable, so tint moves retint it.
          stripFill: Color(nsColor: manager.focusedSurfaceBackground)
            .opacity(manager.ghosttyRuntime.backgroundOpacity()),
          unfocusedOverlay: manager.unfocusedSplitOverlay(),
          surfaceState: { [weak manager] surfaceID in
            manager?.hostIfExists(for: worktree.id)?.surfaceStates[surfaceID]
          },
          isLifecycleBusy: isLifecycleBusy
        )
      } else {
        // No strip is mounted here, so the default "+" hint would point at a
        // control that is not on screen.
        EmptyTerminalPaneView(
          message: "No terminals open",
          hint: Text("Press \(Text("⌘T").bold()) to open a new terminal.")
        )
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
  let stripFill: Color
  let unfocusedOverlay: (fill: Color?, opacity: Double)
  let surfaceState: (UUID) -> WorktreeSurfaceState?
  let isLifecycleBusy: Bool

  var body: some View {
    LayoutContentView(
      store: store,
      runtime: runtime,
      dividerColor: dividerColor,
      stripFill: stripFill,
      unfocusedOverlay: unfocusedOverlay,
      surfaceState: surfaceState,
      isLifecycleBusy: isLifecycleBusy
    )
    .alert($store.scope(state: \.alert, action: \.alert))
  }
}
