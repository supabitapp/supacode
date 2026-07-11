import AppKit
import SwiftUI

struct TerminalSplitTreeView: View {
  let tree: SplitTree<SurfaceView>
  // Owns the per-surface `SurfaceIndicatorState` map; leaves resolve their
  // notification flag through `terminalState.surfaceStates[id]`.
  let terminalState: WorktreeSurfaceState
  // Single source of truth for which pane is active in this tab. Any surface
  // whose id does not match this gets the unfocused-split dim overlay.
  let activeSurfaceID: UUID?
  // Supacode renders surfaces directly (no Ghostty SurfaceWrapper), so the
  // unfocused-pane dim overlay is applied here from the `unfocused-split-fill`
  // and `unfocused-split-opacity` config values. Fill is nil when the config
  // is unreadable; callers must skip the overlay in that case.
  let unfocusedSplitOverlay: (fill: Color?, opacity: Double)
  let action: (Operation) -> Void

  var body: some View {
    if let node = tree.visibleNode {
      SubtreeView(
        node: node,
        isRoot: node == tree.root,
        terminalState: terminalState,
        activeSurfaceID: activeSurfaceID,
        unfocusedSplitOverlay: unfocusedSplitOverlay,
        action: action
      )
      .id(node.structuralIdentity)
    }
  }

  enum Operation {
    case resize(node: SplitTree<SurfaceView>.Node, ratio: Double)
    case drop(payloadId: UUID, destinationId: UUID, zone: DropZone)
    case equalize
  }

  struct SubtreeView: View {
    let node: SplitTree<SurfaceView>.Node
    var isRoot: Bool = false
    let terminalState: WorktreeSurfaceState
    let activeSurfaceID: UUID?
    let unfocusedSplitOverlay: (fill: Color?, opacity: Double)
    let action: (Operation) -> Void

    var body: some View {
      switch node {
      case .leaf(let leafView):
        switch leafView.content {
        case .terminal(let surfaceView):
          LeafView(
            surfaceView: surfaceView,
            surfaceState: terminalState.surfaceStates[leafView.id],
            isSplit: !isRoot,
            activeSurfaceID: activeSurfaceID,
            unfocusedSplitOverlay: unfocusedSplitOverlay,
            dragCoordinator: terminalState.dragCoordinator,
            action: action
          )
        }
      case .split(let split):
        let splitViewDirection: SplitView<SubtreeView, SubtreeView>.Direction =
          switch split.direction {
          case .horizontal: .horizontal
          case .vertical: .vertical
          }
        SplitView(
          splitViewDirection,
          .init(
            get: {
              CGFloat(split.ratio)
            },
            set: {
              action(.resize(node: node, ratio: Double($0)))
            }),
          dividerColor: Color(nsColor: .separatorColor),
          resizeIncrements: .init(width: 1, height: 1),
          left: {
            SubtreeView(
              node: split.left,
              terminalState: terminalState,
              activeSurfaceID: activeSurfaceID,
              unfocusedSplitOverlay: unfocusedSplitOverlay,
              action: action
            )
          },
          right: {
            SubtreeView(
              node: split.right,
              terminalState: terminalState,
              activeSurfaceID: activeSurfaceID,
              unfocusedSplitOverlay: unfocusedSplitOverlay,
              action: action
            )
          },
          onEqualize: {
            action(.equalize)
          }
        )
      }
    }
  }

  struct LeafView: View {
    let surfaceView: GhosttySurfaceView
    let surfaceState: SurfaceIndicatorState?
    let isSplit: Bool
    let activeSurfaceID: UUID?
    let unfocusedSplitOverlay: (fill: Color?, opacity: Double)
    let dragCoordinator: SurfaceDragCoordinator
    let action: (Operation) -> Void

    private var isDimmed: Bool {
      // During initialization activeSurfaceID is nil and nothing should be
      // dimmed.
      guard isSplit, let activeSurfaceID else { return false }
      return activeSurfaceID != surfaceView.id
    }

    var body: some View {
      GhosttyTerminalView(surfaceView: surfaceView)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
          if isDimmed, let fill = unfocusedSplitOverlay.fill, unfocusedSplitOverlay.opacity > 0 {
            fill
              .opacity(unfocusedSplitOverlay.opacity)
              .allowsHitTesting(false)
          }
        }
        .overlay(alignment: .topTrailing) {
          if surfaceView.bridge.state.searchNeedle != nil {
            GhosttySurfaceSearchOverlay(surfaceView: surfaceView)
          }
        }
        .overlay(alignment: .topTrailing) {
          SurfaceNotificationDotIndicator(state: surfaceState)
        }
        .overlay(alignment: .top) {
          if isSplit {
            SurfaceDragHandle(surfaceID: surfaceView.id, coordinator: dragCoordinator)
              .frame(height: handleHeight)
          }
        }
        .overlay {
          // Mounted for the pane's lifetime (not only during a drag) so the catcher's
          // drag-type registration is ready before a drag session starts; AppKit can
          // miss a drop target that registers mid-drag. `SurfaceDropCatcherView.hitTest`
          // keeps it click-through until a drag is in flight.
          SurfaceDropCatcher(surfaceID: surfaceView.id, coordinator: dragCoordinator)
        }
    }

    private let handleHeight: CGFloat = 10
  }

  enum DropZone: String, Equatable {
    case top
    case bottom
    case left
    case right

    static func calculate(at point: CGPoint, in size: CGSize) -> DropZone {
      let relX = point.x / size.width
      let relY = point.y / size.height

      let distToLeft = relX
      let distToRight = 1 - relX
      let distToTop = relY
      let distToBottom = 1 - relY

      let minDist = min(distToLeft, distToRight, distToTop, distToBottom)

      if minDist == distToLeft { return .left }
      if minDist == distToRight { return .right }
      if minDist == distToTop { return .top }
      return .bottom
    }
  }

}

// MARK: - Surface notification indicator.

/// Per-surface dot leaf. Reads `state.hasUnseenNotification` so a notification
/// on this surface invalidates only this overlay, not the entire split tree.
/// Nil while a surface is mid-registration; renders nothing in that window.
private struct SurfaceNotificationDotIndicator: View {
  let state: SurfaceIndicatorState?

  var body: some View {
    let isShowing = state?.hasUnseenNotification == true
    SurfaceNotificationDot()
      .padding(6)
      .opacity(isShowing ? 1 : 0)
      .allowsHitTesting(false)
      .animation(.easeInOut(duration: 0.2), value: isShowing)
  }
}

private struct SurfaceNotificationDot: View {
  @Environment(\.pixelLength) private var pixelLength

  var body: some View {
    Circle()
      .fill(.orange)
      .frame(width: 8, height: 8)
      .overlay(
        Circle()
          .stroke(.background, lineWidth: pixelLength)
      )
      .accessibilityLabel("Unread notifications")
  }
}

// MARK: - Accessibility Container

/// Wraps the SwiftUI split tree in an AppKit view so we can expose an ordered
/// list of terminal panes to assistive technologies.
struct TerminalSplitTreeAXContainer: NSViewRepresentable {
  let tree: SplitTree<SurfaceView>
  let terminalState: WorktreeSurfaceState
  let activeSurfaceID: UUID?
  let unfocusedSplitOverlay: (fill: Color?, opacity: Double)
  let action: (TerminalSplitTreeView.Operation) -> Void

  func makeNSView(context: Context) -> TerminalSplitAXContainerView {
    TerminalSplitAXContainerView()
  }

  func updateNSView(_ nsView: TerminalSplitAXContainerView, context: Context) {
    nsView.update(
      rootView: TerminalSplitTreeView(
        tree: tree,
        terminalState: terminalState,
        activeSurfaceID: activeSurfaceID,
        unfocusedSplitOverlay: unfocusedSplitOverlay,
        action: action
      ),
      panes: tree.visibleLeaves()
    )
  }
}

@MainActor
final class TerminalSplitAXContainerView: NSView {
  // Typed `NSHostingView<TerminalSplitTreeView>` (no `AnyView`) so re-assigning
  // `rootView` on every update lets SwiftUI diff against a stable concrete view
  // type instead of re-walking an erased tree.
  private var hostingView: NSHostingView<TerminalSplitTreeView>?
  private var panes: [SurfaceView] = []
  private var panesLabel: String = "Terminal split: 0 panes"
  private var lastPaneIDs: [UUID] = []

  func update(rootView: TerminalSplitTreeView, panes: [SurfaceView]) {
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

    let newPaneIDs = panes.map(\.id)
    self.panes = panes
    panesLabel = "Terminal split: \(panes.count) pane" + (panes.count == 1 ? "" : "s")

    for (index, pane) in panes.enumerated() {
      switch pane.content {
      case .terminal(let surface):
        surface.setAccessibilityPaneIndex(index: index + 1, total: panes.count)
        // Expose panes as direct children of this split group for predictable navigation.
        surface.setAccessibilityParent(self)
      }
    }

    if newPaneIDs != lastPaneIDs {
      lastPaneIDs = newPaneIDs
      // Assistive tech may cache the AX tree; nudge it to re-query when pane membership/order changes.
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
