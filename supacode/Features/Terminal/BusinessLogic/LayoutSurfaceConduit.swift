import AppKit
import Foundation
import GhosttyKit
import SupacodeSettingsShared

private nonisolated let conduitLogger = SupaLogger("LayoutConduit")

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

  /// Consumes a surface-emitted topology action without acting on it.
  private static func ignoreTopologyAction(_ name: String) -> Bool {
    conduitLogger.debug("Ignored Ghostty topology action \(name).")
    return true
  }

  private func wireTopologyCallbacks(_ view: GhosttySurfaceView, contentID: ContentID, surfaceID: UUID) {
    let host = host
    view.bridge.onTitleChange = { [weak view] title in
      guard let view, isLive(view) else { return }
      host.sendLayoutAction(.runtime(.titleChanged(id: contentID, title: title)))
    }
    // Layout topology belongs to the app's own chords, menus, and palette;
    // a Ghostty keybind for it is consumed and ignored so the terminal can
    // never drive the layout.
    view.bridge.onNewTab = { Self.ignoreTopologyAction("new_tab") }
    view.bridge.onCloseTab = { _ in Self.ignoreTopologyAction("close_tab") }
    view.bridge.onSplitAction = { _ in Self.ignoreTopologyAction("split") }
    view.bridge.onGotoTab = { _ in Self.ignoreTopologyAction("goto_tab") }
    view.bridge.onMoveTab = { _ in Self.ignoreTopologyAction("move_tab") }
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
    // The busyness report is dropped: the reducer's three-way confirm mode
    // re-derives it, so an `.always` user still confirms an idle shell.
    view.bridge.onCloseRequest = { [weak view] _ in
      guard let view, isLive(view) else { return }
      handleCloseRequest(for: view, contentID: contentID)
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
  private func handleCloseRequest(for view: GhosttySurfaceView, contentID: ContentID) {
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
    if host.isFrozenBlockingScriptSurface(surfaceID) {
      guard let tabID = host.tabID(containing: surfaceID) else { return }
      host.sendLayoutAction(.closeTab(id: tabID))
      return
    }
    host.sendLayoutAction(.contentRequestedClose(content: contentID, scope: .tab))
  }
}
