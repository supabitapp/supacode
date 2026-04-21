import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TerminalSplitTreeView: View {
  let tree: SplitTree<GhosttySurfaceView>
  // Single source of truth for which pane is active in this tab. Any surface
  // whose id does not match this gets the unfocused-split dim overlay.
  let activeSurfaceID: UUID?
  // Supacode renders surfaces directly (no Ghostty SurfaceWrapper), so the
  // unfocused-pane dim overlay is applied here from the `unfocused-split-fill`
  // and `unfocused-split-opacity` config values. Fill is nil when the config
  // is unreadable; callers must skip the overlay in that case.
  let unfocusedSplitOverlay: (fill: Color?, opacity: Double)
  // Returns whether a given surface has unread notifications. The closure
  // is read inside the leaf view so SwiftUI picks up per-surface changes
  // via the Observation tracking on the underlying state.
  let hasNotification: (UUID) -> Bool
  let action: (Operation) -> Void

  private static let dragType = UTType(exportedAs: "sh.supacode.ghosttySurfaceId")
  private static func dragProvider(for surfaceView: GhosttySurfaceView) -> NSItemProvider {
    let provider = NSItemProvider()
    let data = surfaceView.id.uuidString.data(using: .utf8) ?? Data()
    provider.registerDataRepresentation(
      forTypeIdentifier: dragType.identifier,
      visibility: .all
    ) { completion in
      completion(data, nil)
      return nil
    }
    return provider
  }

  var body: some View {
    if let node = tree.visibleNode {
      SubtreeView(
        node: node,
        isRoot: node == tree.root,
        activeSurfaceID: activeSurfaceID,
        unfocusedSplitOverlay: unfocusedSplitOverlay,
        hasNotification: hasNotification,
        action: action
      )
      .id(node.structuralIdentity)
    }
  }

  enum Operation {
    case resize(node: SplitTree<GhosttySurfaceView>.Node, ratio: Double)
    case drop(payloadId: UUID, destinationId: UUID, zone: DropZone)
    case equalize
  }

  struct SubtreeView: View {
    let node: SplitTree<GhosttySurfaceView>.Node
    var isRoot: Bool = false
    let activeSurfaceID: UUID?
    let unfocusedSplitOverlay: (fill: Color?, opacity: Double)
    let hasNotification: (UUID) -> Bool
    let action: (Operation) -> Void

    var body: some View {
      switch node {
      case .leaf(let leafView):
        LeafView(
          surfaceView: leafView,
          isSplit: !isRoot,
          activeSurfaceID: activeSurfaceID,
          unfocusedSplitOverlay: unfocusedSplitOverlay,
          hasNotification: hasNotification(leafView.id),
          action: action
        )
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
              activeSurfaceID: activeSurfaceID,
              unfocusedSplitOverlay: unfocusedSplitOverlay,
              hasNotification: hasNotification,
              action: action
            )
          },
          right: {
            SubtreeView(
              node: split.right,
              activeSurfaceID: activeSurfaceID,
              unfocusedSplitOverlay: unfocusedSplitOverlay,
              hasNotification: hasNotification,
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
    let isSplit: Bool
    let activeSurfaceID: UUID?
    let unfocusedSplitOverlay: (fill: Color?, opacity: Double)
    let hasNotification: Bool
    let action: (Operation) -> Void

    @State private var dropState: DropState = .idle

    private var isDimmed: Bool {
      // During initialization activeSurfaceID is nil and nothing should be
      // dimmed.
      guard isSplit, let activeSurfaceID else { return false }
      return activeSurfaceID != surfaceView.id
    }

    var body: some View {
      GeometryReader { geometry in
        GhosttyTerminalView(surfaceView: surfaceView)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .overlay {
            if isDimmed, let fill = unfocusedSplitOverlay.fill, unfocusedSplitOverlay.opacity > 0 {
              fill
                .opacity(unfocusedSplitOverlay.opacity)
                .allowsHitTesting(false)
            }
          }
          .overlay(alignment: .top) {
            GhosttySurfaceProgressOverlay(state: surfaceView.bridge.state)
          }
          .overlay(alignment: .topTrailing) {
            if surfaceView.bridge.state.searchNeedle != nil {
              GhosttySurfaceSearchOverlay(surfaceView: surfaceView)
            }
          }
          .overlay(alignment: .topTrailing) {
            SurfaceNotificationDot()
              .padding(6)
              .opacity(hasNotification ? 1 : 0)
              .allowsHitTesting(false)
              .animation(.easeInOut(duration: 0.2), value: hasNotification)
          }
          .overlay(alignment: .top) {
            if isSplit {
              DragHandle(surfaceView: surfaceView)
            }
          }
          .background {
            Color.clear
              .contentShape(.rect)
              .onDrop(
                of: [TerminalSplitTreeView.dragType],
                delegate: SplitDropDelegate(
                  dropState: $dropState,
                  viewSize: geometry.size,
                  destinationId: surfaceView.id,
                  action: action
                ))
          }
          .overlay {
            if case .dropping(let zone) = dropState {
              DropOverlayView(zone: zone, size: geometry.size)
                .allowsHitTesting(false)
            }
          }
      }
    }

  }

  struct DragHandle: View {
    let surfaceView: GhosttySurfaceView
    private let handleHeight: CGFloat = 10
    @State private var isHovering = false

    var body: some View {
      Rectangle()
        .fill(Color.primary.opacity(isHovering ? 0.12 : 0))
        .frame(maxWidth: .infinity)
        .frame(height: handleHeight)
        .overlay {
          if isHovering {
            Image(systemName: "ellipsis")
              .font(.system(.callout, weight: .semibold))
              .foregroundStyle(.primary.opacity(0.5))
              .accessibilityHidden(true)
          }
        }
        .contentShape(.rect)
        .onHover { hovering in
          guard hovering != isHovering else { return }
          isHovering = hovering
          if hovering {
            NSCursor.openHand.push()
          } else {
            NSCursor.pop()
          }
        }
        .onDisappear {
          if isHovering {
            isHovering = false
            NSCursor.pop()
          }
        }
        .onDrag {
          TerminalSplitTreeView.dragProvider(for: surfaceView)
        }
    }
  }

  enum DropState: Equatable {
    case idle
    case dropping(DropZone)
  }

  struct SplitDropDelegate: DropDelegate {
    @Binding var dropState: DropState
    let viewSize: CGSize
    let destinationId: UUID
    let action: (Operation) -> Void

    func validateDrop(info: DropInfo) -> Bool {
      info.hasItemsConforming(to: [TerminalSplitTreeView.dragType])
    }

    func dropEntered(info: DropInfo) {
      dropState = .dropping(.calculate(at: info.location, in: viewSize))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
      guard case .dropping = dropState else { return DropProposal(operation: .forbidden) }
      dropState = .dropping(.calculate(at: info.location, in: viewSize))
      return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
      dropState = .idle
    }

    func performDrop(info: DropInfo) -> Bool {
      let zone = DropZone.calculate(at: info.location, in: viewSize)
      dropState = .idle

      let providers = info.itemProviders(for: [TerminalSplitTreeView.dragType])
      guard let provider = providers.first else { return false }
      provider.loadDataRepresentation(
        forTypeIdentifier: TerminalSplitTreeView.dragType.identifier
      ) { data, _ in
        guard let data,
          let raw = String(data: data, encoding: .utf8),
          let payloadId = UUID(uuidString: raw)
        else { return }
        Task { @MainActor in
          action(.drop(payloadId: payloadId, destinationId: destinationId, zone: zone))
        }
      }
      return true
    }
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

  struct DropOverlayView: View {
    let zone: DropZone
    let size: CGSize

    var body: some View {
      let overlayColor = Color.accentColor.opacity(0.3)

      switch zone {
      case .top:
        VStack(spacing: 0) {
          Rectangle()
            .fill(overlayColor)
            .frame(height: size.height / 2)
          Spacer()
        }
      case .bottom:
        VStack(spacing: 0) {
          Spacer()
          Rectangle()
            .fill(overlayColor)
            .frame(height: size.height / 2)
        }
      case .left:
        HStack(spacing: 0) {
          Rectangle()
            .fill(overlayColor)
            .frame(width: size.width / 2)
          Spacer()
        }
      case .right:
        HStack(spacing: 0) {
          Spacer()
          Rectangle()
            .fill(overlayColor)
            .frame(width: size.width / 2)
        }
      }
    }
  }
}

// MARK: - Surface notification indicator.

private struct SurfaceNotificationDot: View {
  var body: some View {
    Circle()
      .fill(.orange)
      .frame(width: 8, height: 8)
      .overlay(
        Circle()
          .stroke(.background, lineWidth: 1)
      )
      .accessibilityLabel("Unread notifications")
  }
}

// MARK: - Accessibility Container

/// Wraps the SwiftUI split tree in an AppKit view so we can expose an ordered
/// list of terminal panes to assistive technologies.
struct TerminalSplitTreeAXContainer: NSViewRepresentable {
  let tree: SplitTree<GhosttySurfaceView>
  let activeSurfaceID: UUID?
  let unfocusedSplitOverlay: (fill: Color?, opacity: Double)
  let hasNotification: (UUID) -> Bool
  let action: (TerminalSplitTreeView.Operation) -> Void

  func makeNSView(context: Context) -> TerminalSplitAXContainerView {
    TerminalSplitAXContainerView()
  }

  func updateNSView(_ nsView: TerminalSplitAXContainerView, context: Context) {
    nsView.update(
      rootView: AnyView(
        TerminalSplitTreeView(
          tree: tree,
          activeSurfaceID: activeSurfaceID,
          unfocusedSplitOverlay: unfocusedSplitOverlay,
          hasNotification: hasNotification,
          action: action
        )
      ),
      panes: tree.visibleLeaves()
    )
  }
}

@MainActor
final class TerminalSplitAXContainerView: NSView {
  private var hostingView: NSHostingView<AnyView>?
  private var panes: [GhosttySurfaceView] = []
  private var panesLabel: String = "Terminal split: 0 panes"
  private var lastPaneIDs: [UUID] = []

  func update(rootView: AnyView, panes: [GhosttySurfaceView]) {
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
      pane.setAccessibilityPaneIndex(index: index + 1, total: panes.count)
      // Expose panes as direct children of this split group for predictable navigation.
      pane.setAccessibilityParent(self)
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
