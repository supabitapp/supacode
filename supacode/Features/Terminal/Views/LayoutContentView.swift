import AppKit
import ComposableArchitecture
import SwiftUI

/// Renders one worktree's pane tree inside a stable AppKit container, so live
/// renderer views survive structural rebuilds without reparenting the whole
/// hierarchy, assistive tech sees an ordered pane list, and the window tint
/// mask tracks the terminal body. Layout-agnostic; the parent sizes it.
struct LayoutContentView: View {
  let store: StoreOf<LayoutFeature>
  let runtime: ContentRuntime
  var dividerColor: Color = Color(nsColor: .separatorColor)

  var body: some View {
    // Body reads register the observation; the AppKit container below only
    // receives resolved values.
    let visiblePaneIDs = store.layout.tree.visibleLeaves()
    let _ = store.renderEpoch
    LayoutAXContainer(
      store: store,
      runtime: runtime,
      dividerColor: dividerColor,
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

  var body: some View {
    if let node = store.layout.tree.visibleNode {
      PaneNodeView(node: node, store: store, runtime: runtime, dividerColor: dividerColor)
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
  let panes: [NSView]

  func makeNSView(context: Context) -> LayoutAXContainerView {
    LayoutAXContainerView()
  }

  func updateNSView(_ nsView: LayoutAXContainerView, context: Context) {
    nsView.update(
      rootView: LayoutPaneTreeView(store: store, runtime: runtime, dividerColor: dividerColor),
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

  var body: some View {
    switch node {
    case .leaf(let paneID):
      PaneStripView(paneID: paneID, store: store, runtime: runtime)
    case .split(let split):
      PaneSplitView(node: node, split: split, store: store, runtime: runtime, dividerColor: dividerColor)
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

  var body: some View {
    SplitView(
      split.direction,
      ratio: split.ratio,
      dividerColor: dividerColor,
      left: {
        PaneNodeView(node: split.left, store: store, runtime: runtime, dividerColor: dividerColor)
      },
      right: {
        PaneNodeView(node: split.right, store: store, runtime: runtime, dividerColor: dividerColor)
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

  private var pane: Pane? { store.layout.panes[id: paneID] }
  private var isFocused: Bool { store.layout.focusedPaneID == paneID }

  var body: some View {
    if let pane {
      VStack(spacing: 0) {
        PaneTabStrip(pane: pane, isFocused: isFocused, store: store)
        Divider()
        if let contentID = pane.selectedTab?.content.id {
          // The epoch read keeps this branch re-evaluating on hibernate/wake;
          // a visible content without a renderer (failed wake, vanished
          // worktree) gets an explicit placeholder, never a silent blank.
          let epoch = store.renderEpoch
          if runtime.renderer(for: contentID) != nil {
            ContentHostView(contentID: contentID, runtime: runtime, epoch: epoch)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
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

/// The horizontal strip of a pane's tabs, with the selected one highlighted.
private struct PaneTabStrip: View {
  let pane: Pane
  let isFocused: Bool
  let store: StoreOf<LayoutFeature>

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 2) {
        ForEach(pane.tabs) { tab in
          PaneTabButton(
            tab: tab,
            isSelected: pane.selectedTabID == tab.id,
            store: store
          )
        }
      }
      .padding(.horizontal, 4)
      .padding(.vertical, 3)
    }
    .background(isFocused ? Color(nsColor: .controlBackgroundColor) : Color(nsColor: .windowBackgroundColor))
  }
}

/// A single tab in a pane strip; selects on click, closes on the accessory.
private struct PaneTabButton: View {
  let tab: TabItem
  let isSelected: Bool
  let store: StoreOf<LayoutFeature>

  var body: some View {
    HStack(spacing: 4) {
      Button {
        store.send(.selectTab(id: tab.id))
      } label: {
        Text(tab.customTitle ?? tab.title)
          .lineLimit(1)
          .font(.callout)
      }
      .buttonStyle(.plain)
      .help("Select this tab.")
      Button {
        // Through the confirm gate: the three-way close-tab mode decides
        // whether this needs an alert.
        store.send(.contentRequestedClose(content: tab.content.id, scope: .tab))
      } label: {
        Image(systemName: "xmark")
          .imageScale(.small)
          .accessibilityLabel("Close tab")
      }
      .buttonStyle(.plain)
      .help("Close this tab.")
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(isSelected ? Color(nsColor: .selectedControlColor) : .clear, in: .rect(cornerRadius: 6))
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
