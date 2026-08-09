import AppKit
import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

/// Renders one worktree's pane tree inside a stable AppKit container, so live
/// renderer views survive structural rebuilds without reparenting the whole
/// hierarchy, assistive tech sees an ordered pane list, and the window tint
/// mask tracks the terminal body. Layout-agnostic; the parent sizes it.
struct LayoutContentView: View {
  let store: StoreOf<LayoutFeature>
  let runtime: ContentRuntime
  var dividerColor: Color = Color(nsColor: .separatorColor)
  /// Chrome fill behind each tab strip: the strip sits inside the window
  /// tint's mask hole, so it must repaint the tint or transparent windows
  /// show raw blur above every pane.
  var stripFill: Color = .clear
  /// The `unfocused-split-fill` dim painted over visible unfocused panes.
  var unfocusedOverlay: (fill: Color?, opacity: Double) = (nil, 0)
  /// Resolves a content id to its observable unseen-notification counter.
  var surfaceState: (UUID) -> WorktreeSurfaceState? = { _ in nil }
  /// Workspace lifecycle work, represented on the focused pane's selected tab.
  var isLifecycleBusy = false
  // Captured here, in the outer SwiftUI world, and re-injected past the
  // NSHostingView boundary, which environment objects do not cross.
  @Environment(GhosttyShortcutManager.self) private var ghosttyShortcuts
  @Environment(CommandKeyObserver.self) private var commandKeyObserver

  var body: some View {
    // Body reads register the observation; the AppKit container below only
    // receives resolved values.
    let visiblePaneIDs = store.layout.tree.visibleLeaves()
    let _ = store.renderEpoch
    LayoutAXContainer(
      store: store,
      runtime: runtime,
      dividerColor: dividerColor,
      stripFill: stripFill,
      unfocusedOverlay: unfocusedOverlay,
      surfaceState: surfaceState,
      isLifecycleBusy: isLifecycleBusy,
      ghosttyShortcuts: ghosttyShortcuts,
      commandKeyObserver: commandKeyObserver,
      panes: visiblePaneIDs.compactMap { paneID in
        store.layout.panes[id: paneID]?.selectedTab.flatMap { runtime.renderer(for: $0.content.id) }
      }
    )
  }
}

/// Renders the pane tree itself: the split structure over panes, each pane a
/// tab strip above its selected content.
struct LayoutPaneTreeView: View {
  let store: StoreOf<LayoutFeature>
  let runtime: ContentRuntime
  let dividerColor: Color
  var stripFill: Color = .clear
  var unfocusedOverlay: (fill: Color?, opacity: Double) = (nil, 0)
  var surfaceState: (UUID) -> WorktreeSurfaceState? = { _ in nil }
  var isLifecycleBusy = false
  var ghosttyShortcuts: GhosttyShortcutManager?
  var commandKeyObserver: CommandKeyObserver?

  var body: some View {
    Group {
      if let node = store.layout.tree.visibleNode {
        // Panes flow down BY VALUE from this `.id` boundary: a structural
        // change swaps the subtree, so the dismantling copy keeps its frozen
        // pane values and can never retarget a host to post-swap state and
        // steal its renderer into the dying hierarchy.
        PaneNodeView(
          node: node, panes: store.layout.panes, store: store, runtime: runtime,
          dividerColor: dividerColor,
          stripFill: stripFill, unfocusedOverlay: unfocusedOverlay, surfaceState: surfaceState,
          isLifecycleBusy: isLifecycleBusy
        )
        .id(store.layout.tree.structuralIdentity)
      } else {
        EmptyLayoutView()
      }
    }
    .environment(ghosttyShortcuts)
    .environment(commandKeyObserver)
  }
}

/// Wraps the pane tree in an AppKit view exposing an ordered pane list to
/// assistive technologies, mirroring the split-tree container it replaces.
private struct LayoutAXContainer: NSViewRepresentable {
  let store: StoreOf<LayoutFeature>
  let runtime: ContentRuntime
  let dividerColor: Color
  let stripFill: Color
  let unfocusedOverlay: (fill: Color?, opacity: Double)
  let surfaceState: (UUID) -> WorktreeSurfaceState?
  let isLifecycleBusy: Bool
  let ghosttyShortcuts: GhosttyShortcutManager?
  let commandKeyObserver: CommandKeyObserver?
  let panes: [NSView]

  func makeNSView(context: Context) -> LayoutAXContainerView {
    LayoutAXContainerView()
  }

  func updateNSView(_ nsView: LayoutAXContainerView, context: Context) {
    nsView.update(
      rootView: LayoutPaneTreeView(
        store: store, runtime: runtime, dividerColor: dividerColor,
        stripFill: stripFill, unfocusedOverlay: unfocusedOverlay, surfaceState: surfaceState,
        isLifecycleBusy: isLifecycleBusy,
        ghosttyShortcuts: ghosttyShortcuts, commandKeyObserver: commandKeyObserver),
      panes: panes
    )
  }
}

@MainActor
final class LayoutAXContainerView: NSView, WindowTintMaskRegion {
  // Typed hosting view (no `AnyView`) so re-assigning `rootView` lets SwiftUI
  // diff against a stable concrete view type.
  private var hostingView: NSHostingView<LayoutPaneTreeView>?
  private var panes: [NSView] = []
  private var panesLabel = "Terminal split: 0 panes"
  private var lastPaneIDs: [ObjectIdentifier] = []

  func update(rootView: LayoutPaneTreeView, panes: [NSView]) {
    if let hostingView {
      hostingView.rootView = rootView
    } else {
      let hostingView = NSHostingView(rootView: rootView)
      // The window uses a full-size content view; without this the hosted
      // tree insets below the titlebar wherever the container overlaps it.
      hostingView.safeAreaRegions = []
      hostingView.translatesAutoresizingMaskIntoConstraints = false
      addSubview(hostingView)
      NSLayoutConstraint.activate([
        hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
        hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
        hostingView.topAnchor.constraint(equalTo: topAnchor),
        hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
      ])
      self.hostingView = hostingView
    }

    let newPaneIDs = panes.map(ObjectIdentifier.init)
    self.panes = panes
    panesLabel = "Terminal split: \(panes.count) pane" + (panes.count == 1 ? "" : "s")

    for (index, pane) in panes.enumerated() {
      (pane as? GhosttySurfaceView)?.setAccessibilityPaneIndex(index: index + 1, total: panes.count)
      // Expose panes as direct children of this split group for predictable
      // navigation.
      pane.setAccessibilityParent(self)
    }

    if newPaneIDs != lastPaneIDs {
      lastPaneIDs = newPaneIDs
      // Assistive tech may cache the AX tree; nudge it to re-query when pane
      // membership or order changes.
      NSAccessibility.post(element: self, notification: .layoutChanged)
    }
  }

  // Drive the window tint mask: this container's bounds are the hole cut out
  // of the tint, so the terminal body composites over blur.
  override func layout() {
    super.layout()
    NotificationCenter.default.post(name: .ghosttyTintMaskRegionDidChange, object: self)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    NotificationCenter.default.post(name: .ghosttyTintMaskRegionDidChange, object: self)
  }

  override func isAccessibilityElement() -> Bool {
    true
  }

  override func accessibilityRole() -> NSAccessibility.Role? {
    // AppKit doesn't provide a named constant for this role.
    NSAccessibility.Role(rawValue: "AXSplitGroup")
  }

  override func accessibilityLabel() -> String? {
    panesLabel
  }

  override func accessibilityChildren() -> [Any]? {
    panes
  }
}

/// Defense in depth: the parent gates on non-empty panes, so a consistent
/// layout always has a visible node; this only renders if that invariant slips.
private struct EmptyLayoutView: View {
  var body: some View {
    ContentUnavailableView("No Terminals", systemImage: "terminal")
  }
}

/// One node of the pane tree: a split renders its children with a draggable
/// divider, a leaf renders its pane.
private struct PaneNodeView: View {
  let node: SplitTree<PaneID>.Node
  let panes: IdentifiedArrayOf<Pane>
  let store: StoreOf<LayoutFeature>
  let runtime: ContentRuntime
  let dividerColor: Color
  let stripFill: Color
  let unfocusedOverlay: (fill: Color?, opacity: Double)
  let surfaceState: (UUID) -> WorktreeSurfaceState?
  let isLifecycleBusy: Bool

  var body: some View {
    switch node {
    case .leaf(let paneID):
      if let pane = panes[id: paneID] {
        PaneStripView(
          pane: pane, store: store, runtime: runtime, stripFill: stripFill,
          unfocusedOverlay: unfocusedOverlay,
          surfaceState: surfaceState, isLifecycleBusy: isLifecycleBusy)
      }
    case .split(let split):
      PaneSplitView(
        node: node, split: split, panes: panes, store: store, runtime: runtime,
        dividerColor: dividerColor,
        stripFill: stripFill, unfocusedOverlay: unfocusedOverlay, surfaceState: surfaceState,
        isLifecycleBusy: isLifecycleBusy)
    }
  }
}

/// A split of two child nodes; the divider drag resizes and a double-click
/// equalizes, both through the reducer.
private struct PaneSplitView: View {
  let node: SplitTree<PaneID>.Node
  let split: SplitTree<PaneID>.Split
  let panes: IdentifiedArrayOf<Pane>
  let store: StoreOf<LayoutFeature>
  let runtime: ContentRuntime
  let dividerColor: Color
  let stripFill: Color
  let unfocusedOverlay: (fill: Color?, opacity: Double)
  let surfaceState: (UUID) -> WorktreeSurfaceState?
  let isLifecycleBusy: Bool

  var body: some View {
    SplitView(
      split.direction,
      ratio: split.ratio,
      dividerColor: dividerColor,
      left: {
        PaneNodeView(
          node: split.left, panes: panes, store: store, runtime: runtime,
          dividerColor: dividerColor,
          stripFill: stripFill, unfocusedOverlay: unfocusedOverlay, surfaceState: surfaceState,
          isLifecycleBusy: isLifecycleBusy)
      },
      right: {
        PaneNodeView(
          node: split.right, panes: panes, store: store, runtime: runtime,
          dividerColor: dividerColor,
          stripFill: stripFill, unfocusedOverlay: unfocusedOverlay, surfaceState: surfaceState,
          isLifecycleBusy: isLifecycleBusy)
      },
      onResize: { store.send(.resizePane(node: node, ratio: $0)) },
      onEqualize: { store.send(.equalizePanes) }
    )
  }
}

/// A pane: its tab strip and the selected tab's content. A single-tab pane
/// still shows its strip, matching the current chrome. The pane arrives by
/// value from the `.id` boundary, never read from the store here, so a
/// dismantling copy can never see post-swap selection.
private struct PaneStripView: View {
  let pane: Pane
  let store: StoreOf<LayoutFeature>
  let runtime: ContentRuntime
  let stripFill: Color
  let unfocusedOverlay: (fill: Color?, opacity: Double)
  let surfaceState: (UUID) -> WorktreeSurfaceState?
  let isLifecycleBusy: Bool

  private var isFocused: Bool { store.layout.focusedPaneID == pane.id }
  private var isZoomed: Bool {
    guard case .leaf(let leaf) = store.layout.tree.zoomed else { return false }
    return leaf == pane.id
  }

  /// Only a multi-pane view dims; the sole visible pane (single pane or
  /// zoomed) is always the working one.
  private var isDimmed: Bool {
    !isFocused && store.layout.tree.visibleLeaves().count > 1
  }

  var body: some View {
    VStack(spacing: 0) {
      PaneTabStrip(
        pane: pane,
        isFocusedPane: isFocused,
        isZoomed: isZoomed,
        isLifecycleBusy: isLifecycleBusy,
        store: store,
        runtime: runtime,
        surfaceState: surfaceState
      )
      .background(stripFill)
      if let contentID = pane.selectedTab?.content.id {
        // The epoch read keeps this branch re-evaluating on hibernate/wake;
        // a visible content without a renderer (failed wake, vanished
        // worktree) gets an explicit placeholder, never a silent blank.
        let epoch = store.renderEpoch
        if runtime.renderer(for: contentID) != nil {
          ContentHostView(contentID: contentID, runtime: runtime, epoch: epoch)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
              if isDimmed, let fill = unfocusedOverlay.fill, unfocusedOverlay.opacity > 0 {
                fill
                  .opacity(unfocusedOverlay.opacity)
                  .allowsHitTesting(false)
              }
            }
        } else {
          EmptyTerminalPaneView(message: "This terminal is unavailable.")
        }
      } else {
        Color.clear
      }
    }
  }
}

/// Hosts a content's renderer view, resolved from the runtime and swapped when
/// the content hibernates or wakes.
private struct ContentHostView: NSViewRepresentable {
  let contentID: ContentID
  let runtime: ContentRuntime
  /// The runtime is not observable; the reducer bumps this on hibernate and
  /// wake so `updateNSView` re-runs even when the layout value is unchanged.
  let epoch: UInt64

  /// This host's claim on the content it last mounted. Structural rebuilds
  /// briefly overlap old and new hosts for the same content; the claim keeps
  /// a stale host's late update from stealing the renderer back into the
  /// dying hierarchy, which left survivor panes permanently blank.
  final class Coordinator {
    var claimedContentID: ContentID?
    var claim: UInt64 = 0
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> NSView {
    let container = NSView()
    claim(context.coordinator)
    mount(into: container)
    return container
  }

  func updateNSView(_ container: NSView, context: Context) {
    // Retargeting to another content (tab switch) re-claims; the same content
    // only mounts while this host still holds the newest claim.
    if context.coordinator.claimedContentID != contentID {
      claim(context.coordinator)
    }
    guard runtime.isCurrentRenderHost(context.coordinator.claim, for: contentID) else { return }
    mount(into: container)
  }

  private func claim(_ coordinator: Coordinator) {
    coordinator.claimedContentID = contentID
    coordinator.claim = runtime.claimRenderHost(for: contentID)
  }

  private func mount(into container: NSView) {
    guard let renderer = runtime.renderer(for: contentID) else {
      container.subviews.forEach { $0.removeFromSuperview() }
      return
    }
    let hostedView: NSView
    if let surface = renderer as? GhosttySurfaceView {
      // Terminals mount through the scroll wrapper: it owns the surface's
      // frame, the overlay scroller, and zeroes the window safe-area insets.
      if let wrapper = container.subviews.first as? GhosttySurfaceScrollView,
        surface.scrollWrapper === wrapper
      {
        return
      }
      hostedView = GhosttySurfaceScrollView(surfaceView: surface)
    } else {
      // Already showing the right renderer: nothing to do.
      if container.subviews.first === renderer { return }
      hostedView = renderer
    }
    container.subviews.forEach { $0.removeFromSuperview() }
    hostedView.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(hostedView)
    NSLayoutConstraint.activate([
      hostedView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      hostedView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      hostedView.topAnchor.constraint(equalTo: container.topAnchor),
      hostedView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
  }
}
