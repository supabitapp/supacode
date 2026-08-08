import AppKit
import ComposableArchitecture
import SwiftUI

/// One worktree's terminal area on the layout engine: the pane tree with its
/// close-confirmation alert. Mirrors the envelope `WorktreeTerminalTabsView`
/// provided on the legacy path.
struct WorktreeLayoutView: View {
  let worktree: Worktree
  let manager: WorktreeTerminalManager
  let terminalsStore: StoreOf<TerminalsFeature>
  let runtime: ContentRuntime

  var body: some View {
    // Re-read config-derived colors on every Ghostty config reload.
    let _ = manager.configGeneration
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
