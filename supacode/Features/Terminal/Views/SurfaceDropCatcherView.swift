import AppKit
import SupacodeSettingsShared
import SwiftUI
import UniformTypeIdentifiers

private let catcherLogger = SupaLogger("SurfaceDrag")

/// Transparent drop target mounted over a leaf's content **only while a pane is
/// being dragged** (the view layer gates this on `SurfaceDragCoordinator
/// .isDragging`). It registers solely for `SurfaceView.surfaceDragType`, so it
/// only ever catches a rearrange drag — never a content drop (a Finder file, an
/// image), which carries a disjoint type and falls through to the surface below.
/// Being a real AppKit `NSView` placed in front of the hosted content lets it win
/// the drag even over a greedy child view (e.g. a future `WKWebView`).
struct SurfaceDropCatcher: NSViewRepresentable {
  let surfaceID: UUID
  let coordinator: SurfaceDragCoordinator

  func makeNSView(context: Context) -> SurfaceDropCatcherView {
    SurfaceDropCatcherView(surfaceID: surfaceID, coordinator: coordinator)
  }

  func updateNSView(_ nsView: SurfaceDropCatcherView, context: Context) {}
}

final class SurfaceDropCatcherView: NSView {
  private let surfaceID: UUID
  private weak var coordinator: SurfaceDragCoordinator?
  /// Half-pane accent highlight for the zone under the cursor.
  private let indicator = NSView()

  init(surfaceID: UUID, coordinator: SurfaceDragCoordinator) {
    self.surfaceID = surfaceID
    self.coordinator = coordinator
    super.init(frame: .zero)
    wantsLayer = true
    indicator.wantsLayer = true
    indicator.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor
    indicator.isHidden = true
    addSubview(indicator)
    registerForDraggedTypes([NSPasteboard.PasteboardType(SurfaceView.surfaceDragType.identifier)])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  // The catcher is mounted for the pane's whole lifetime so its drag-type
  // registration is in place before a drag session starts (AppKit acquires its
  // drop-target set at session start; a target that registers mid-drag can be
  // missed). It must therefore stay click-through until a pane drag is actually
  // in flight, or it would swallow normal clicks on the surface content.
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard coordinator?.isDragging == true else { return nil }
    return super.hitTest(point)
  }

  override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
    let zone = showIndicator(for: sender)
    catcherLogger.debug("catcher entered leaf=\(surfaceID) zone=\(zone.rawValue)")
    return .move
  }

  override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
    _ = showIndicator(for: sender)
    return .move
  }

  override func draggingExited(_ sender: (any NSDraggingInfo)?) {
    indicator.isHidden = true
  }

  override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    true
  }

  override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    indicator.isHidden = true
    guard
      let coordinator,
      let payloadID = SurfaceDragCoordinator.payloadID(from: sender.draggingPasteboard)
    else { return false }
    coordinator.completeDrop(payloadID: payloadID, destinationID: surfaceID, zone: zone(for: sender))
    return true
  }

  @discardableResult
  private func showIndicator(for sender: any NSDraggingInfo) -> TerminalSplitTreeView.DropZone {
    let zone = zone(for: sender)
    indicator.frame = Self.indicatorFrame(for: zone, in: bounds)
    indicator.isHidden = false
    return zone
  }

  /// `draggingLocation` is window-space and AppKit views are bottom-left origin
  /// (no surface overrides `isFlipped`), so flip Y into the top-left space
  /// `DropZone.calculate` expects.
  private func zone(for sender: any NSDraggingInfo) -> TerminalSplitTreeView.DropZone {
    let point = convert(sender.draggingLocation, from: nil)
    return .calculate(at: CGPoint(x: point.x, y: bounds.height - point.y), in: bounds.size)
  }

  /// Half of `bounds` on the chosen edge, in bottom-left AppKit coordinates
  /// (so `.top` is the upper half = higher y).
  static func indicatorFrame(for zone: TerminalSplitTreeView.DropZone, in bounds: CGRect) -> CGRect {
    let halfWidth = bounds.width / 2
    let halfHeight = bounds.height / 2
    switch zone {
    case .top: return CGRect(x: 0, y: halfHeight, width: bounds.width, height: halfHeight)
    case .bottom: return CGRect(x: 0, y: 0, width: bounds.width, height: halfHeight)
    case .left: return CGRect(x: 0, y: 0, width: halfWidth, height: bounds.height)
    case .right: return CGRect(x: halfWidth, y: 0, width: halfWidth, height: bounds.height)
    }
  }
}
