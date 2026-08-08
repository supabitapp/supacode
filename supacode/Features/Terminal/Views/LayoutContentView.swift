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

  var body: some View {
    // Body reads register the observation; the AppKit container below only
    // receives resolved values.
    let visiblePaneIDs = store.layout.tree.visibleLeaves()
    let _ = store.renderEpoch
    LayoutAXContainer(
      store: store,
      runtime: runtime,
      dividerColor: dividerColor,
      unfocusedOverlay: unfocusedOverlay,
      surfaceState: surfaceState,
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
  var unfocusedOverlay: (fill: Color?, opacity: Double) = (nil, 0)
  var surfaceState: (UUID) -> WorktreeSurfaceState? = { _ in nil }

  var body: some View {
    if let node = store.layout.tree.visibleNode {
      PaneNodeView(
        node: node, store: store, runtime: runtime, dividerColor: dividerColor,
        unfocusedOverlay: unfocusedOverlay, surfaceState: surfaceState)
        .id(store.layout.tree.structuralIdentity)
    } else {
      EmptyLayoutView()
    }
  }
}

/// Wraps the pane tree in an AppKit view exposing an ordered pane list to
/// assistive technologies, mirroring the split-tree container it replaces.
private struct LayoutAXContainer: NSViewRepresentable {
  let store: StoreOf<LayoutFeature>
  let runtime: ContentRuntime
  let dividerColor: Color
  let unfocusedOverlay: (fill: Color?, opacity: Double)
  let surfaceState: (UUID) -> WorktreeSurfaceState?
  let panes: [NSView]

  func makeNSView(context: Context) -> LayoutAXContainerView {
    LayoutAXContainerView()
  }

  func updateNSView(_ nsView: LayoutAXContainerView, context: Context) {
    nsView.update(
      rootView: LayoutPaneTreeView(
        store: store, runtime: runtime, dividerColor: dividerColor,
        unfocusedOverlay: unfocusedOverlay, surfaceState: surfaceState),
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

/// Shown when a layout has no panes: closing the final tab empties it until a
/// new tab is created.
private struct EmptyLayoutView: View {
  var body: some View {
    ContentUnavailableView("No Terminals", systemImage: "terminal")
  }
}

/// One node of the pane tree: a split renders its children with a draggable
/// divider, a leaf renders its pane.
private struct PaneNodeView: View {
  let node: SplitTree<PaneID>.Node
  let store: StoreOf<LayoutFeature>
  let runtime: ContentRuntime
  let dividerColor: Color
  let unfocusedOverlay: (fill: Color?, opacity: Double)
  let surfaceState: (UUID) -> WorktreeSurfaceState?

  var body: some View {
    switch node {
    case .leaf(let paneID):
      PaneStripView(
        paneID: paneID, store: store, runtime: runtime, unfocusedOverlay: unfocusedOverlay,
        surfaceState: surfaceState)
    case .split(let split):
      PaneSplitView(
        node: node, split: split, store: store, runtime: runtime, dividerColor: dividerColor,
        unfocusedOverlay: unfocusedOverlay, surfaceState: surfaceState)
    }
  }
}

/// A split of two child nodes; the divider drag resizes and a double-click
/// equalizes, both through the reducer.
private struct PaneSplitView: View {
  let node: SplitTree<PaneID>.Node
  let split: SplitTree<PaneID>.Split
  let store: StoreOf<LayoutFeature>
  let runtime: ContentRuntime
  let dividerColor: Color
  let unfocusedOverlay: (fill: Color?, opacity: Double)
  let surfaceState: (UUID) -> WorktreeSurfaceState?

  var body: some View {
    SplitView(
      split.direction,
      ratio: split.ratio,
      dividerColor: dividerColor,
      left: {
        PaneNodeView(
          node: split.left, store: store, runtime: runtime, dividerColor: dividerColor,
          unfocusedOverlay: unfocusedOverlay, surfaceState: surfaceState)
      },
      right: {
        PaneNodeView(
          node: split.right, store: store, runtime: runtime, dividerColor: dividerColor,
          unfocusedOverlay: unfocusedOverlay, surfaceState: surfaceState)
      },
      onResize: { store.send(.resizePane(node: node, ratio: $0)) },
      onEqualize: { store.send(.equalizePanes) }
    )
  }
}

/// A pane: its tab strip and the selected tab's content. A single-tab pane
/// still shows its strip, matching the current chrome.
private struct PaneStripView: View {
  let paneID: PaneID
  let store: StoreOf<LayoutFeature>
  let runtime: ContentRuntime
  let unfocusedOverlay: (fill: Color?, opacity: Double)
  let surfaceState: (UUID) -> WorktreeSurfaceState?

  private var pane: Pane? { store.layout.panes[id: paneID] }
  private var isFocused: Bool { store.layout.focusedPaneID == paneID }
  /// Only a multi-pane view dims; the sole visible pane (single pane or
  /// zoomed) is always the working one.
  private var isDimmed: Bool {
    !isFocused && store.layout.tree.visibleLeaves().count > 1
  }

  var body: some View {
    if let pane {
      VStack(spacing: 0) {
        PaneTabStrip(
          pane: pane, isFocused: isFocused, store: store, runtime: runtime, surfaceState: surfaceState)
        Divider()
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
      .contentShape(.rect)
      .onTapGesture { store.send(.focusPane(.pane(paneID))) }
      .accessibilityAddTraits(.isButton)
    }
  }
}

/// The horizontal strip of a pane's tabs plus the new-tab accessory; a drop
/// past the last tab appends to this pane.
private struct PaneTabStrip: View {
  let pane: Pane
  let isFocused: Bool
  let store: StoreOf<LayoutFeature>
  let runtime: ContentRuntime
  let surfaceState: (UUID) -> WorktreeSurfaceState?

  var body: some View {
    HStack(spacing: 0) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 2) {
          ForEach(pane.tabs) { tab in
            PaneTabButton(
              tab: tab,
              pane: pane,
              isSelected: pane.selectedTabID == tab.id,
              store: store,
              runtime: runtime,
              surfaceState: surfaceState
            )
          }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
      }
      newTabButton
    }
    .background(isFocused ? Color(nsColor: .controlBackgroundColor) : Color(nsColor: .windowBackgroundColor))
    .dropDestination(for: String.self) { items, _ in
      // A drop on the strip body (past the tabs) appends to this pane.
      PaneTabDrag.performDrop(items, into: pane, at: pane.tabs.count, store: store)
    }
  }

  private var newTabButton: some View {
    Button {
      guard let contentID = pane.selectedTab?.content.id else { return }
      store.send(.contentRequestedNewTab(content: contentID))
    } label: {
      Image(systemName: "plus")
        .imageScale(.small)
        .frame(width: 22, height: 22)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("New tab")
    .help("Open a new tab in this pane (⌘T).")
    .padding(.trailing, 4)
  }
}

/// Resolves tab-strip drag payloads into `moveTab` sends. The payload is the
/// tab's UUID string, so a drop from another worktree's window simply fails
/// the local lookup and is ignored.
private enum PaneTabDrag {
  @MainActor
  static func performDrop(
    _ items: [String],
    into pane: Pane,
    at index: Int,
    store: StoreOf<LayoutFeature>
  ) -> Bool {
    guard let raw = items.first, let uuid = UUID(uuidString: raw) else { return false }
    let tabID = TabID(rawValue: uuid)
    guard let sourcePane = store.layout.pane(containingTab: tabID) else { return false }
    var target = index
    if sourcePane.id == pane.id,
      let sourceIndex = sourcePane.tabs.index(id: tabID), sourceIndex < index {
      // The reducer removes the source before inserting; compensate so a
      // rightward drag still inserts before the tab it was dropped on.
      target -= 1
    }
    store.send(.moveTab(id: tabID, toPane: pane.id, index: target))
    return true
  }
}

/// A single tab in a pane strip: chrome (icon, tint, badges, progress
/// stripe), selection, hover close, context menu, inline rename, and drag
/// reorder within or across strips.
private struct PaneTabButton: View {
  let tab: TabItem
  let pane: Pane
  let isSelected: Bool
  let store: StoreOf<LayoutFeature>
  let runtime: ContentRuntime
  let surfaceState: (UUID) -> WorktreeSurfaceState?

  @State private var isHovering = false
  @State private var isEditing = false
  @State private var editingTitle = ""
  @FocusState private var isFieldFocused: Bool
  @Environment(\.pixelLength) private var pixelLength

  var body: some View {
    let badge = store.agentBadges[tab.content.id]
    let _ = store.renderEpoch
    let surface = runtime.renderer(for: tab.content.id) as? GhosttySurfaceView
    let progress = surface.flatMap { live in
      TerminalTabProgressDisplay.make(
        progressState: live.bridge.state.progressState,
        progressValue: live.bridge.state.progressValue
      )
    }
    HStack(spacing: 4) {
      if surface == nil {
        // Semibold compensates for the zzz glyph's thin strokes.
        Image(systemName: "zzz")
          .imageScale(.small)
          .fontWeight(.semibold)
          .foregroundStyle(.secondary)
          .accessibilityLabel("Hibernated tab")
          .help("Hibernated to save resources. Select to reconnect.")
      }
      if let badge, !badge.agents.isEmpty {
        AgentAvatarGroupView(instances: badge.agents, size: 14)
      }
      if let icon = tab.icon {
        Image(systemName: icon)
          .imageScale(.small)
          .foregroundStyle(tab.tintColor?.color ?? .primary)
          .accessibilityHidden(true)
      }
      if isEditing {
        renameField
      } else {
        selectButton(isShimmering: badge?.isWorking == true)
      }
      trailingAccessory
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(isSelected ? Color(nsColor: .selectedControlColor) : .clear, in: .rect(cornerRadius: 6))
    .overlay(alignment: .top) {
      PaneTabStripe(
        isSelected: isSelected,
        tintColor: tab.tintColor,
        progressDisplay: progress,
        pixelLength: pixelLength
      )
    }
    .onHover { isHovering = $0 }
    .draggable(tab.id.rawValue.uuidString)
    .dropDestination(for: String.self) { items, _ in
      // Dropping on a tab inserts before it.
      guard let index = pane.tabs.index(id: tab.id) else { return false }
      return PaneTabDrag.performDrop(items, into: pane, at: index, store: store)
    }
    .contextMenu { contextMenuItems }
  }

  private func selectButton(isShimmering: Bool) -> some View {
    Button {
      store.send(.selectTab(id: tab.id))
    } label: {
      Text(tab.customTitle ?? tab.title)
        .lineLimit(1)
        .font(.callout)
        .shimmer(isActive: isShimmering)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .help("Select this tab.")
    .simultaneousGesture(
      TapGesture(count: 2).onEnded {
        beginRename()
      }
    )
  }

  private var renameField: some View {
    TextField("", text: $editingTitle)
      .textFieldStyle(.plain)
      .font(.callout)
      .focused($isFieldFocused)
      .frame(minWidth: 60)
      .onSubmit { commitRename() }
      .onExitCommand {
        isEditing = false
      }
      .onChange(of: isFieldFocused) {
        // Focus loss commits like Enter; only Escape cancels.
        if !isFieldFocused, isEditing {
          commitRename()
        }
      }
  }

  @ViewBuilder
  private var trailingAccessory: some View {
    if isHovering, !isEditing {
      Button {
        // Through the confirm gate: the three-way close-tab mode decides
        // whether this needs an alert.
        store.send(.contentRequestedClose(content: tab.content.id, scope: .tab))
      } label: {
        Image(systemName: "xmark")
          .imageScale(.small)
          .accessibilityLabel("Close tab")
          .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .help("Close this tab (⌘W).")
    } else if store.agentBadges[tab.content.id] == nil,
      let state = surfaceStateForUnseenDot, state.hasUnseenNotification {
      Circle()
        .fill(.tint)
        .frame(width: 6, height: 6)
        .accessibilityLabel("Unread notifications")
    }
  }

  /// The per-content unseen counter, observable so a read here re-renders
  /// only this tab when the count moves.
  private var surfaceStateForUnseenDot: WorktreeSurfaceState? {
    surfaceState(tab.content.id.rawValue)
  }

  @ViewBuilder
  private var contextMenuItems: some View {
    Button("Rename Tab…") { beginRename() }
      .disabled(tab.isTitleLocked)
    Divider()
    Button("Close Tab") {
      store.send(.contentRequestedClose(content: tab.content.id, scope: .tab))
    }
    Button("Close Other Tabs") {
      store.send(.contentRequestedClose(content: tab.content.id, scope: .otherTabs))
    }
    .disabled(pane.tabs.count < 2)
    Button("Close Tabs to the Right") {
      store.send(.contentRequestedClose(content: tab.content.id, scope: .tabsToTheRight))
    }
    .disabled(pane.tabs.last?.id == tab.id)
  }

  private func beginRename() {
    guard !tab.isTitleLocked else { return }
    editingTitle = tab.customTitle ?? ""
    isEditing = true
    isFieldFocused = true
  }

  private func commitRename() {
    guard isEditing else { return }
    isEditing = false
    // An empty commit clears the override on every commit path.
    store.send(.renameTab(id: tab.id, title: editingTitle))
  }
}

/// Top-of-tab stripe carrying the tint and the OSC 9 progress signal.
private struct PaneTabStripe: View {
  let isSelected: Bool
  let tintColor: RepositoryColor?
  let progressDisplay: TerminalTabProgressDisplay?
  let pixelLength: CGFloat

  var body: some View {
    if isSelected || tintColor != nil || progressDisplay != nil {
      ZStack(alignment: .leading) {
        Rectangle()
          .fill(isDeterminate ? color.opacity(0.3) : color)
        if case .determinate(let percent) = progressDisplay?.style {
          // scaleEffect composites the fill (no relayout); the percent is
          // bucketed upstream so agent ticks don't thrash layout.
          Rectangle()
            .fill(color)
            .scaleEffect(x: CGFloat(max(0, min(percent, 100))) / 100, anchor: .leading)
        }
      }
      .frame(maxWidth: .infinity)
      .frame(height: 2)
      .padding(.horizontal, -pixelLength)
      .opacity(isSelected ? 1 : 0.7)
      .allowsHitTesting(false)
      .accessibilityLabel(progressDisplay?.accessibilityValue ?? "")
    }
  }

  private var isDeterminate: Bool {
    if case .determinate = progressDisplay?.style { return true }
    return false
  }

  /// Progress states override the tab tint; the untinted fallback paints
  /// `.secondary` so the selected indicator stays visible without an
  /// accent-color flash.
  private var color: Color {
    switch progressDisplay?.style {
    case .error: .red
    case .paused: .orange
    case .indeterminate, .determinate: tintColor?.color ?? .accentColor
    case nil: tintColor?.color ?? .secondary
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

  func makeNSView(context: Context) -> NSView {
    let container = NSView()
    mount(into: container)
    return container
  }

  func updateNSView(_ container: NSView, context: Context) {
    mount(into: container)
  }

  private func mount(into container: NSView) {
    let renderer = runtime.renderer(for: contentID)
    // Already showing the right renderer (or both nil): nothing to do.
    if container.subviews.first === renderer { return }
    container.subviews.forEach { $0.removeFromSuperview() }
    guard let renderer else { return }
    renderer.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(renderer)
    NSLayoutConstraint.activate([
      renderer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      renderer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      renderer.topAnchor.constraint(equalTo: container.topAnchor),
      renderer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
  }
}
