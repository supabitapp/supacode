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
  /// The `unfocused-split-fill` dim painted over visible unfocused panes.
  var unfocusedOverlay: (fill: Color?, opacity: Double) = (nil, 0)
  /// Resolves a content id to its observable unseen-notification counter.
  var surfaceState: (UUID) -> WorktreeSurfaceState? = { _ in nil }
  /// Workspace lifecycle work, represented on the focused pane's selected tab.
  var isLifecycleBusy = false
  /// Brings a windowed pane's window to the front.
  var showWindowedPane: (PaneID) -> Void = { _ in }
  // Captured here, in the outer SwiftUI world, and re-injected past the
  // NSHostingView boundary, which environment objects do not cross.
  @Environment(GhosttyShortcutManager.self) private var ghosttyShortcuts
  @Environment(CommandKeyObserver.self) private var commandKeyObserver
  /// One drag source per worktree layout, stable across rebuilds.
  @State private var dragModel = PaneTabDragModel()

  var body: some View {
    // Body reads register the observation; the AppKit container below only
    // receives resolved values.
    let visiblePaneIDs = store.layout.tree.visibleLeaves()
    let _ = store.renderEpoch
    LayoutAXContainer(
      store: store,
      renderContext: PaneRenderContext(
        runtime: runtime,
        dividerColor: dividerColor,
        unfocusedOverlay: unfocusedOverlay,
        surfaceState: surfaceState,
        isLifecycleBusy: isLifecycleBusy,
        showWindowedPane: showWindowedPane,
        dragModel: dragModel
      ),
      ghosttyShortcuts: ghosttyShortcuts,
      commandKeyObserver: commandKeyObserver,
      // Windowed panes render in their own windows; their surfaces are not
      // this container's AX children.
      panes: visiblePaneIDs.compactMap { paneID in
        guard !store.windowedPaneIDs.contains(paneID) else { return nil }
        return store.layout.panes[id: paneID]?.selectedTab.flatMap { runtime.renderer(for: $0.content.id) }
      }
    )
  }
}

/// The values every pane renders with, constant across the tree; bundled so
/// the recursive node views forward one value instead of seven.
struct PaneRenderContext {
  let runtime: ContentRuntime
  var dividerColor: Color = Color(nsColor: .separatorColor)
  var unfocusedOverlay: (fill: Color?, opacity: Double) = (nil, 0)
  var surfaceState: (UUID) -> WorktreeSurfaceState? = { _ in nil }
  var isLifecycleBusy = false
  var showWindowedPane: (PaneID) -> Void = { _ in }
  /// Shared tab-drag source, so a pane's split zones can gray out invalid drops.
  var dragModel = PaneTabDragModel()
}

/// Renders the pane tree itself: the split structure over panes, each pane a
/// tab strip above its selected content.
struct LayoutPaneTreeView: View {
  let store: StoreOf<LayoutFeature>
  let renderContext: PaneRenderContext
  var ghosttyShortcuts: GhosttyShortcutManager?
  var commandKeyObserver: CommandKeyObserver?

  var body: some View {
    Group {
      if let node = store.layout.tree.visibleNode {
        // Panes and the windowed set flow down by value from this `.id`
        // boundary, so a dismantling copy cannot retarget a content host to
        // post-swap state.
        PaneNodeView(
          node: node, panes: store.layout.panes, windowedPaneIDs: store.windowedPaneIDs,
          store: store, renderContext: renderContext
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
  let renderContext: PaneRenderContext
  let ghosttyShortcuts: GhosttyShortcutManager?
  let commandKeyObserver: CommandKeyObserver?
  let panes: [NSView]

  func makeNSView(context: Context) -> LayoutAXContainerView {
    LayoutAXContainerView()
  }

  func updateNSView(_ nsView: LayoutAXContainerView, context: Context) {
    nsView.update(
      rootView: LayoutPaneTreeView(
        store: store, renderContext: renderContext,
        ghosttyShortcuts: ghosttyShortcuts, commandKeyObserver: commandKeyObserver),
      panes: panes
    )
  }
}

@MainActor
final class LayoutAXContainerView: NSView {
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
  private static let logger = SupaLogger("LayoutContentView")

  let node: SplitTree<PaneID>.Node
  let panes: IdentifiedArrayOf<Pane>
  /// Frozen alongside `panes`: a live read here would let a dismantling copy
  /// swap a placeholder back to a strip and steal the survivor's renderer.
  let windowedPaneIDs: Set<PaneID>
  let store: StoreOf<LayoutFeature>
  let renderContext: PaneRenderContext

  var body: some View {
    switch node {
    case .leaf(let paneID):
      if let pane = panes[id: paneID] {
        if windowedPaneIDs.contains(paneID) {
          WindowedPanePlaceholderView(paneID: paneID, store: store, showWindow: renderContext.showWindowedPane)
        } else {
          PaneStripView(
            pane: pane, windowedPaneIDs: windowedPaneIDs, store: store,
            runtime: renderContext.runtime,
            unfocusedOverlay: renderContext.unfocusedOverlay,
            surfaceState: renderContext.surfaceState,
            isLifecycleBusy: renderContext.isLifecycleBusy,
            dragModel: renderContext.dragModel)
        }
      } else {
        // Tree and panes disagree; render an explicit fallback, never a hole.
        EmptyTerminalPaneView(
          message: "This pane is unavailable.",
          hint: Text("Reopen the worktree to rebuild its layout.")
        )
        .onAppear {
          Self.logger.error("Tree leaf \(paneID.rawValue) has no pane; layout state is inconsistent.")
        }
      }
    case .split(let split):
      PaneSplitView(
        node: node, split: split, panes: panes, windowedPaneIDs: windowedPaneIDs,
        store: store, renderContext: renderContext)
    }
  }
}

/// A split of two child nodes; the divider drag resizes and a double-click
/// equalizes, both through the reducer.
private struct PaneSplitView: View {
  let node: SplitTree<PaneID>.Node
  let split: SplitTree<PaneID>.Split
  let panes: IdentifiedArrayOf<Pane>
  let windowedPaneIDs: Set<PaneID>
  let store: StoreOf<LayoutFeature>
  let renderContext: PaneRenderContext

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// The full-span preview direction when an in-flight span drop is anchored on
  /// one of this split's own panes; this split frames both, so it paints the
  /// highlight across the divider.
  private var spanPreviewDirection: SplitTree<PaneID>.NewDirection? {
    guard let target = renderContext.dragModel.spanTarget,
      split.left == .leaf(view: target.anchorPaneID) || split.right == .leaf(view: target.anchorPaneID)
    else { return nil }
    return target.direction
  }

  var body: some View {
    SplitView(
      split.direction,
      ratio: split.ratio,
      dividerColor: renderContext.dividerColor,
      left: {
        PaneNodeView(
          node: split.left, panes: panes, windowedPaneIDs: windowedPaneIDs,
          store: store, renderContext: renderContext)
      },
      right: {
        PaneNodeView(
          node: split.right, panes: panes, windowedPaneIDs: windowedPaneIDs,
          store: store, renderContext: renderContext)
      },
      onResize: { store.send(.resizePane(node: node, ratio: $0)) },
      onEqualize: { store.send(.equalizePanes) }
    )
    .overlay {
      if let spanPreviewDirection {
        PaneSpanDropPreview(direction: spanPreviewDirection).transition(.opacity)
      }
    }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: spanPreviewDirection)
  }
}

/// A pane: its tab strip and the selected tab's content. The pane value is a
/// parameter, never looked up from the store, so a dismantling copy of the
/// embedded tree cannot retarget the content host to post-swap selection.
/// `.windowed` renders the same strip in a pane's own window: no drop zones,
/// no dim.
struct PaneStripView: View {
  enum Context {
    case embedded
    case windowed
  }

  let pane: Pane
  let windowedPaneIDs: Set<PaneID>
  let store: StoreOf<LayoutFeature>
  let runtime: ContentRuntime
  var unfocusedOverlay: (fill: Color?, opacity: Double) = (nil, 0)
  var surfaceState: (UUID) -> WorktreeSurfaceState? = { _ in nil }
  var isLifecycleBusy = false
  var context: Context = .embedded
  /// Shared tab-drag source; nil in a pane window, where there are no drop zones.
  var dragModel: PaneTabDragModel?

  private var isFocused: Bool { store.layout.focusedPaneID == pane.id }
  private var isZoomed: Bool {
    guard case .leaf(let leaf) = store.layout.tree.zoomed else { return false }
    return leaf == pane.id
  }

  /// Only a multi-pane view dims; the sole visible pane (single pane or
  /// zoomed) is always the working one. A windowed pane never dims, and its
  /// placeholder leaf does not count as company.
  private var isDimmed: Bool {
    guard context == .embedded, !isFocused else { return false }
    return Set(store.layout.tree.visibleLeaves()).subtracting(windowedPaneIDs).count > 1
  }

  var body: some View {
    VStack(spacing: 0) {
      PaneTabStrip(
        pane: pane,
        isFocusedPane: isFocused,
        isZoomed: isZoomed,
        isWindowed: context == .windowed,
        isLifecycleBusy: isLifecycleBusy,
        store: store,
        runtime: runtime,
        surfaceState: surfaceState,
        dragModel: dragModel
      )
      Group {
        if let contentID = pane.selectedTab?.content.id {
          // The epoch read keeps this branch re-evaluating on hibernate/wake;
          // a visible content without a renderer (failed wake, vanished
          // worktree) gets an explicit placeholder, never a silent blank.
          let epoch = store.renderEpoch
          if runtime.renderer(for: contentID) != nil {
            ContentHostView(contentID: contentID, runtime: runtime, epoch: epoch)
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
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      // On the whole content region, so a dormant pane still takes drops.
      .overlay {
        if context == .embedded, let dragModel {
          PaneSplitDropZones(pane: pane, store: store, dragModel: dragModel)
        }
      }
    }
  }
}

/// Placeholder leaf for a pane rendering in its own window.
private struct WindowedPanePlaceholderView: View {
  let paneID: PaneID
  let store: StoreOf<LayoutFeature>
  let showWindow: (PaneID) -> Void

  var body: some View {
    ContentUnavailableView {
      Label("In Separate Window", systemImage: "macwindow.on.rectangle")
    } description: {
      Text("This pane is open in its own window.")
    } actions: {
      Button("Show Window") {
        showWindow(paneID)
      }
      .help("Bring the pane's window to the front")
      Button("Exit Window Mode") {
        store.send(.exitWindowMode(paneID: paneID))
      }
      .help("Return the pane to this layout")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// Edge drop zones over a pane's content: dropping a dragged tab on an edge
/// splits the pane toward it, previewing the half the new pane will occupy.
/// The zones register only the private tab-drag payload, so file drags still
/// reach the terminal beneath.
private struct PaneSplitDropZones: View {
  let pane: Pane
  let store: StoreOf<LayoutFeature>
  let dragModel: PaneTabDragModel

  @State private var targetedDirection: SplitTree<PaneID>.NewDirection?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// The pane's shared divider, if any: the edge the full-span band sits
  /// against and the two perpendicular directions it offers.
  private struct SpanBand {
    let alignment: Alignment
    let isVertical: Bool
    let near: SplitTree<PaneID>.NewDirection
    let far: SplitTree<PaneID>.NewDirection
  }

  private var spanBand: SpanBand? {
    guard let info = store.layout.tree.parentSplitInfo(ofLeaf: pane.id) else { return nil }
    switch info.axis {
    case .horizontal:
      // Side-by-side: divider is vertical, full-span is top / down, and the
      // band is a vertical strip against the divider edge.
      return SpanBand(alignment: info.isLeadingChild ? .trailing : .leading, isVertical: true, near: .top, far: .down)
    case .vertical:
      // Stacked: divider is horizontal, full-span is left / right, band is a
      // horizontal strip against the divider edge.
      return SpanBand(alignment: info.isLeadingChild ? .bottom : .top, isVertical: false, near: .left, far: .right)
    }
  }

  var body: some View {
    HStack(spacing: 0) {
      PaneSplitDropZone(
        direction: .left, pane: pane, store: store, dragModel: dragModel, targeted: $targetedDirection)
      VStack(spacing: 0) {
        PaneSplitDropZone(
          direction: .top, pane: pane, store: store, dragModel: dragModel, targeted: $targetedDirection)
        PaneSplitDropZone(
          direction: .down, pane: pane, store: store, dragModel: dragModel, targeted: $targetedDirection)
      }
      PaneSplitDropZone(
        direction: .right, pane: pane, store: store, dragModel: dragModel, targeted: $targetedDirection)
    }
    // The divider band sits above the per-pane zones so it wins near the shared
    // edge; away from the divider the per-pane split still takes. The full-span
    // preview is painted by the parent split, which reaches across both panes.
    .overlay { spanZones }
    .overlay {
      if let targetedDirection {
        PaneSplitDropPreview(direction: targetedDirection).transition(.opacity)
      }
    }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: targetedDirection)
  }

  @ViewBuilder private var spanZones: some View {
    if let band = spanBand {
      let near = PaneSpanDropZone(
        direction: band.near, pane: pane, store: store, dragModel: dragModel)
      let far = PaneSpanDropZone(
        direction: band.far, pane: pane, store: store, dragModel: dragModel)
      Group {
        if band.isVertical {
          VStack(spacing: 0) {
            near
            far
          }.frame(width: PaneSplitDropMetrics.dividerBand)
        } else {
          HStack(spacing: 0) {
            near
            far
          }.frame(height: PaneSplitDropMetrics.dividerBand)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: band.alignment)
    }
  }
}

private enum PaneSplitDropMetrics {
  /// Width / height of the divider-adjacent full-span band.
  static let dividerBand: CGFloat = 52
  /// Thickness of the full-span preview bar.
  static let spanBar: CGFloat = 10
}

/// One directional drop target; invisible, it only participates in tab drags.
private struct PaneSplitDropZone: View {
  let direction: SplitTree<PaneID>.NewDirection
  let pane: Pane
  let store: StoreOf<LayoutFeature>
  let dragModel: PaneTabDragModel
  @Binding var targeted: SplitTree<PaneID>.NewDirection?

  var body: some View {
    Color.clear
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .dropDestination(for: PaneTabDragPayload.self) { items, _ in
        PaneTabDrag.performSplitDrop(items, anchor: pane, direction: direction, store: store, dragModel: dragModel)
      } isTargeted: { isTargeted in
        // Only preview a drop the pane would actually take, so hovering a tab
        // over its own single-tab pane does not light up.
        if isTargeted, PaneTabDrag.canSplitDrop(sourceTabID: dragModel.sourceTabID, anchor: pane, store: store) {
          targeted = direction
        } else if targeted == direction {
          targeted = nil
        }
      }
  }
}

/// Semi-transparent accent highlight over the half the new pane will occupy.
private struct PaneSplitDropPreview: View {
  let direction: SplitTree<PaneID>.NewDirection

  var body: some View {
    // Two equal flexible children split the pane in half without measuring.
    switch direction {
    case .left:
      HStack(spacing: 0) {
        PaneSplitDropHighlight()
        Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    case .right:
      HStack(spacing: 0) {
        Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        PaneSplitDropHighlight()
      }
    case .top:
      VStack(spacing: 0) {
        PaneSplitDropHighlight()
        Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    case .down:
      VStack(spacing: 0) {
        Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        PaneSplitDropHighlight()
      }
    }
  }
}

/// The accent fill-and-border card previewing the half a drop will occupy.
private struct PaneSplitDropHighlight: View {
  var body: some View {
    RoundedRectangle(cornerRadius: 6)
      .fill(Color.accentColor.opacity(0.2))
      .overlay {
        RoundedRectangle(cornerRadius: 6)
          .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1.5)
      }
      .padding(3)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .allowsHitTesting(false)
  }
}

/// One full-span drop target in the divider band; dropping here wraps the
/// shared parent split so the new pane spans both siblings. Targeting publishes
/// to the shared drag model so the parent split paints the spanning preview.
private struct PaneSpanDropZone: View {
  let direction: SplitTree<PaneID>.NewDirection
  let pane: Pane
  let store: StoreOf<LayoutFeature>
  let dragModel: PaneTabDragModel

  var body: some View {
    Color.clear
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .dropDestination(for: PaneTabDragPayload.self) { items, _ in
        PaneTabDrag.performSpanningSplitDrop(
          items, anchor: pane, direction: direction, store: store, dragModel: dragModel)
      } isTargeted: { isTargeted in
        let target = PaneTabDragModel.SpanTarget(anchorPaneID: pane.id, direction: direction)
        if isTargeted, PaneTabDrag.canSplitDrop(sourceTabID: dragModel.sourceTabID, anchor: pane, store: store) {
          dragModel.spanTarget = target
        } else if dragModel.spanTarget == target {
          dragModel.spanTarget = nil
        }
      }
  }
}

/// Previews a full-span drop as an accent bar along the edge where the new
/// spanning pane will appear.
private struct PaneSpanDropPreview: View {
  let direction: SplitTree<PaneID>.NewDirection

  private var bar: some View {
    RoundedRectangle(cornerRadius: 4)
      .fill(Color.accentColor.opacity(0.35))
      .overlay {
        RoundedRectangle(cornerRadius: 4)
          .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5)
      }
      .allowsHitTesting(false)
  }

  var body: some View {
    switch direction {
    case .top:
      VStack(spacing: 0) {
        bar.frame(height: PaneSplitDropMetrics.spanBar)
        Color.clear
      }
    case .down:
      VStack(spacing: 0) {
        Color.clear
        bar.frame(height: PaneSplitDropMetrics.spanBar)
      }
    case .left:
      HStack(spacing: 0) {
        bar.frame(width: PaneSplitDropMetrics.spanBar)
        Color.clear
      }
    case .right:
      HStack(spacing: 0) {
        Color.clear
        bar.frame(width: PaneSplitDropMetrics.spanBar)
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
  /// and window-mode flips briefly overlap two hosts for one content; the
  /// claim keeps a stale host's late update from stealing the renderer.
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
