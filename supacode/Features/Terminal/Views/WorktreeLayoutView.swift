import AppKit
import ComposableArchitecture
import Sharing
import SupacodeSettingsShared
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
  let newTerminal: FocusedAction<Void>
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
      // An empty layout renders the hint instead of an empty pane tree.
      if let layoutStore = terminalsStore.scope(
        state: \.layouts[id: worktree.id],
        action: \.layouts[id: worktree.id]
      ), !layoutStore.layout.panes.isEmpty {
        LayoutAlertHost(
          store: layoutStore,
          runtime: runtime,
          dividerColor: manager.splitDividerColor(),
          unfocusedOverlay: manager.unfocusedSplitOverlay(),
          surfaceState: { [weak manager] surfaceID in
            manager?.hostIfExists(for: worktree.id)?.surfaceStates[surfaceID]
          },
          isLifecycleBusy: isLifecycleBusy,
          showWindowedPane: { [weak manager] paneID in
            manager?.paneWindows.orderFront(worktreeID: worktree.id, paneID: paneID)
          }
        )
      } else {
        EmptyWorktreeTerminalView(newTerminal: newTerminal)
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
    // Catch a focus intent that lands after the first appearance.
    .onChange(of: forceAutoFocus) { _, focus in
      if focus { host?.focusSelectedTab() }
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

/// The tab-less state: no strip is mounted, so it carries its own new-tab button.
private struct EmptyWorktreeTerminalView: View {
  let newTerminal: FocusedAction<Void>

  @Shared(.settingsFile) private var settingsFile

  var body: some View {
    let title = "New Terminal Tab"
    let shortcut = AppShortcuts.newTerminalTab.effective(from: settingsFile.global.shortcutOverrides)
    let hint =
      AppShortcut.display(of: shortcut).map {
        Text("Press \(Text(verbatim: $0).bold()) or click New Terminal Tab to open one.")
      }
      ?? Text("Click New Terminal Tab to open one.")
    EmptyTerminalPaneView(
      message: "No terminals open",
      hint: hint,
      action: .init(
        title: title,
        systemImage: "plus",
        help: AppShortcut.helpText(title, shortcut: shortcut),
        perform: newTerminal
      )
    )
  }
}

/// Hosts the pane tree and binds the layout's close-confirmation alert.
private struct LayoutAlertHost: View {
  @Bindable var store: StoreOf<LayoutFeature>
  let runtime: ContentRuntime
  let dividerColor: Color
  let unfocusedOverlay: (fill: Color?, opacity: Double)
  let surfaceState: (UUID) -> WorktreeSurfaceState?
  let isLifecycleBusy: Bool
  let showWindowedPane: (PaneID) -> Void

  /// Alerts raised from a windowed pane present in that pane's window; this
  /// host owns the rest.
  private var presentsAlert: Bool {
    store.alertPaneID.map { !store.windowedPaneIDs.contains($0) } ?? true
  }

  var body: some View {
    LayoutContentView(
      store: store,
      runtime: runtime,
      dividerColor: dividerColor,
      unfocusedOverlay: unfocusedOverlay,
      surfaceState: surfaceState,
      isLifecycleBusy: isLifecycleBusy,
      showWindowedPane: showWindowedPane
    )
    .background {
      if presentsAlert {
        Color.clear.alert($store.scope(state: \.alert, action: \.alert))
      }
    }
  }
}
