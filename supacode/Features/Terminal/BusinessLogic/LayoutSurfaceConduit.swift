import AppKit
import Foundation
import GhosttyKit

/// Wires a freshly built terminal surface's callbacks: topology requests
/// route into the worktree's `LayoutFeature` as content-addressed actions,
/// cross-feature signals route into the worktree's content host.
@MainActor
struct LayoutSurfaceConduit {
  let host: WorktreeContentHost
  let runtime: ContentRuntime
  /// Handles a zmx-backed surface that closed without an explicit user close;
  /// the integration layer probes the session and spares, kills, or reattaches.
  let handleUnexpectedZmxClose: (GhosttySurfaceView) -> Void

  func wire(_ view: GhosttySurfaceView, contentID: ContentID) {
    let surfaceID = contentID.rawValue
    // Counters must exist from provision, not first wake, or unseen
    // notifications on a fresh surface never increment.
    host.registerSurfaceState(for: surfaceID)
    wireTopologyCallbacks(view, contentID: contentID, surfaceID: surfaceID)
    wireLifecycleCallbacks(view, contentID: contentID, surfaceID: surfaceID)
  }

  /// Identity, not key presence: a replaced surface keeps its UUID, so stale
  /// closures from the old view must no-op.
  private func isLive(_ view: GhosttySurfaceView) -> Bool {
    host.liveSurface(view.id) === view
  }

  private func wireTopologyCallbacks(_ view: GhosttySurfaceView, contentID: ContentID, surfaceID: UUID) {
    let host = host
    view.bridge.onTitleChange = { [weak view] title in
      guard let view, isLive(view) else { return }
      host.sendLayoutAction(.runtime(.titleChanged(id: contentID, title: title)))
    }
    view.bridge.onNewTab = { [weak view] in
      guard let view, isLive(view) else { return false }
      host.sendLayoutAction(.contentRequestedNewTab(content: contentID))
      return true
    }
    view.bridge.onCloseTab = { [weak view] mode in
      guard let view, isLive(view) else { return false }
      // Ghostty's palette / keybind close-tab carries the scope; honor each so
      // "close others" / "close to the right" route through confirmation too.
      let scope: LayoutFeature.CloseScope =
        switch mode {
        case GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER: .otherTabs
        case GHOSTTY_ACTION_CLOSE_TAB_MODE_RIGHT: .tabsToTheRight
        default: .tab
        }
      host.sendLayoutAction(.contentRequestedClose(content: contentID, scope: scope))
      return true
    }
    view.bridge.onSplitAction = { [weak view] action in
      guard let view, isLive(view) else { return false }
      host.sendLayoutAction(Self.layoutAction(for: action, content: contentID))
      return true
    }
    view.bridge.onGotoTab = { [weak view] target in
      guard let view, isLive(view) else { return false }
      guard let tabTarget = Self.tabTarget(target) else { return false }
      host.sendLayoutAction(.contentRequestedGotoTab(content: contentID, target: tabTarget))
      return true
    }
    view.bridge.onMoveTab = { [weak view] move in
      guard let view, isLive(view) else { return false }
      host.sendLayoutAction(.contentRequestedMoveTab(content: contentID, amount: Int(move.amount)))
      return true
    }
    view.bridge.onCommandPaletteToggle = { [weak view] in
      guard let view, isLive(view) else { return false }
      host.onCommandPaletteToggle?()
      return true
    }
  }

  private func wireLifecycleCallbacks(_ view: GhosttySurfaceView, contentID: ContentID, surfaceID: UUID) {
    let host = host
    let handleUnexpectedZmxClose = handleUnexpectedZmxClose
    view.bridge.onProgressReport = { [weak view] _ in
      guard let view, isLive(view), let tabID = host.tabID(containing: surfaceID) else { return }
      host.updateRunningState(for: tabID)
    }
    view.bridge.onCommandFinished = { [weak view] exitCode in
      guard let view, isLive(view), let tabID = host.tabID(containing: surfaceID) else { return }
      host.handleBlockingScriptCommandFinished(tabID: tabID, exitCode: exitCode)
    }
    view.bridge.onChildExited = { [weak view] exitCode in
      guard let view, isLive(view), let tabID = host.tabID(containing: surfaceID) else { return }
      host.handleBlockingScriptChildExited(tabID: tabID, exitCode: exitCode)
    }
    view.bridge.onDesktopNotification = { [weak view] title, body in
      guard let view, isLive(view) else { return }
      host.handleAgentOSCNotification(title: title, body: body, surfaceID: surfaceID)
    }
    view.bridge.onContextSignal = { [weak view] _, id, metadata in
      guard let view, isLive(view) else { return }
      host.handleContextSignal(surfaceID: surfaceID, id: id, metadata: metadata)
    }
    view.bridge.onColorChanged = { [weak view] in
      guard let view, isLive(view) else { return }
      host.handleSurfaceColorChanged(surfaceID)
    }
    view.bridge.onCloseRequest = { [weak view] needsConfirmation in
      guard let view, isLive(view) else { return }
      handleCloseRequest(for: view, contentID: contentID, needsConfirmation: needsConfirmation)
    }
    view.onFocusChange = { [weak view] focused in
      guard let view, focused, isLive(view) else { return }
      // Pane focus first: the tint and mark-read reads in
      // `recordActiveSurface` must see the updated focused pane.
      host.sendLayoutAction(.contentRequestedFocus(content: contentID))
      host.recordActiveSurface(surfaceID)
      host.emitTaskStatusIfChanged()
    }
    view.onOcclusionHeal = { [weak view] windowIsKey, windowIsVisible in
      guard let view, isLive(view) else { return }
      // Stamp only what the window reports; input alone must not mark covered
      // notifications viewed or keep a covered surface rendering.
      host.syncFocus(windowIsKey: windowIsKey, windowIsVisible: windowIsVisible)
    }
    view.shouldClaimFocus = { [weak view] in
      guard let view, isLive(view) else { return false }
      return host.shouldClaimFocus(surfaceID)
    }
  }

  /// The surface asked to close. Explicit user closes route through the
  /// layout's confirm-close flow; an unexpected zmx exit goes to the probe.
  private func handleCloseRequest(
    for view: GhosttySurfaceView,
    contentID: ContentID,
    needsConfirmation: Bool
  ) {
    let surfaceID = contentID.rawValue
    // Programmatic destroys (deeplink / CLI) skip the alert outright, so the
    // close goes straight to the layout, never through the confirm mode.
    if host.consumeBypassCloseConfirmation(for: surfaceID) {
      _ = host.consumeExplicitClose(for: surfaceID)
      guard let tabID = host.tabID(containing: surfaceID) else { return }
      host.sendLayoutAction(.closeTab(id: tabID))
      return
    }
    let isExplicit = host.consumeExplicitClose(for: surfaceID)
    // A live zmx-backed content is exactly a hibernatable one.
    if !isExplicit, runtime.content(for: contentID)?.isHibernatable == true {
      // Not user-initiated and zmx-backed: probe before deciding to kill,
      // spare, or reattach.
      handleUnexpectedZmxClose(view)
      return
    }
    // A completed blocking script's parked runner keeps reporting a
    // confirmation nothing live justifies; close it straight away.
    if host.isFrozenBlockingScriptSurface(surfaceID) || !needsConfirmation {
      guard let tabID = host.tabID(containing: surfaceID) else { return }
      host.sendLayoutAction(.closeTab(id: tabID))
      return
    }
    host.sendLayoutAction(.contentRequestedClose(content: contentID, scope: .tab))
  }

  // MARK: - Ghostty mappings.

  private static func layoutAction(
    for action: GhosttySplitAction,
    content contentID: ContentID
  ) -> LayoutFeature.Action {
    switch action {
    case .newSplit(let direction):
      .contentRequestedSplit(content: contentID, direction: newDirection(direction))
    case .gotoSplit(let direction):
      .contentRequestedFocusSplit(content: contentID, direction: focusDirection(direction))
    case .resizeSplit(let direction, let amount):
      .contentRequestedResize(content: contentID, direction: spatialDirection(direction), amount: amount)
    case .equalizeSplits:
      .equalizePanes
    case .toggleSplitZoom:
      .contentRequestedToggleZoom(content: contentID)
    }
  }

  private static func newDirection(
    _ direction: GhosttySplitAction.NewDirection
  ) -> SplitTree<PaneID>.NewDirection {
    switch direction {
    case .left: .left
    case .right: .right
    case .top: .top
    case .down: .down
    }
  }

  private static func focusDirection(
    _ direction: GhosttySplitAction.FocusDirection
  ) -> SplitTree<PaneID>.FocusDirection {
    switch direction {
    case .previous: .previous
    case .next: .next
    case .left: .spatial(.left)
    case .right: .spatial(.right)
    case .top: .spatial(.top)
    case .down: .spatial(.down)
    }
  }

  private static func spatialDirection(
    _ direction: GhosttySplitAction.ResizeDirection
  ) -> SplitTree<PaneID>.SpatialDirection {
    switch direction {
    case .left: .left
    case .right: .right
    case .top: .top
    case .down: .down
    }
  }

  private static func tabTarget(_ target: ghostty_action_goto_tab_e) -> LayoutFeature.TabTarget? {
    let raw = Int(target.rawValue)
    if raw > 0 {
      return .position(raw)
    }
    switch raw {
    case Int(GHOSTTY_GOTO_TAB_PREVIOUS.rawValue): return .previous
    case Int(GHOSTTY_GOTO_TAB_NEXT.rawValue): return .next
    case Int(GHOSTTY_GOTO_TAB_LAST.rawValue): return .last
    default: return nil
    }
  }
}
