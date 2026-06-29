import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The grab strip at the top of a split pane. Dragging it starts an AppKit
/// `NSDraggingSession` carrying the leaf's id, which a `SurfaceDropCatcherView`
/// over another pane resolves into a re-split.
///
/// This is an AppKit drag *source* (not SwiftUI `.onDrag`) for two reasons: an
/// `NSDraggingSession` paints the OS floating drag image over other apps, and
/// its `NSDraggingSource` `willBegin`/`ended` callbacks give a reliable
/// drag-in-flight signal (including cancel) that drives catcher mount/unmount —
/// SwiftUI `.onDrag` has no end signal.
struct SurfaceDragHandle: NSViewRepresentable {
  let surfaceID: UUID
  let coordinator: SurfaceDragCoordinator

  func makeNSView(context: Context) -> SurfaceDragHandleView {
    SurfaceDragHandleView(surfaceID: surfaceID, coordinator: coordinator)
  }

  func updateNSView(_ nsView: SurfaceDragHandleView, context: Context) {
    nsView.coordinator = coordinator
  }
}

final class SurfaceDragHandleView: NSView, NSDraggingSource {
  private let surfaceID: UUID
  weak var coordinator: SurfaceDragCoordinator?

  private let ellipsis: NSImageView = {
    let view = NSImageView()
    view.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
    view.contentTintColor = NSColor.labelColor.withAlphaComponent(0.5)
    view.isHidden = true
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private var isHovering = false {
    didSet {
      guard isHovering != oldValue else { return }
      ellipsis.isHidden = !isHovering
      layer?.backgroundColor =
        isHovering ? NSColor.labelColor.withAlphaComponent(0.12).cgColor : nil
    }
  }

  init(surfaceID: UUID, coordinator: SurfaceDragCoordinator) {
    self.surfaceID = surfaceID
    self.coordinator = coordinator
    super.init(frame: .zero)
    wantsLayer = true
    addSubview(ellipsis)
    NSLayoutConstraint.activate([
      ellipsis.centerXAnchor.constraint(equalTo: centerXAnchor),
      ellipsis.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  // MARK: Hover

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach { removeTrackingArea($0) }
    addTrackingArea(
      NSTrackingArea(
        rect: bounds,
        options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
        owner: self,
        userInfo: nil))
  }

  override func mouseEntered(with event: NSEvent) { isHovering = true }
  override func mouseExited(with event: NSEvent) { isHovering = false }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .openHand)
  }

  // MARK: Drag source

  override func mouseDragged(with event: NSEvent) {
    let item = NSPasteboardItem()
    item.setString(
      surfaceID.uuidString,
      forType: NSPasteboard.PasteboardType(SurfaceView.surfaceDragType.identifier))
    let dragItem = NSDraggingItem(pasteboardWriter: item)
    dragItem.setDraggingFrame(bounds, contents: snapshot())
    beginDraggingSession(with: [dragItem], event: event, source: self)
  }

  func draggingSession(
    _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation {
    .move
  }

  func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
    coordinator?.beginDrag(sourceID: surfaceID)
  }

  func draggingSession(
    _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
  ) {
    coordinator?.endDrag()
  }

  /// Bitmap of the strip, used as the floating drag image (matches the snapshot
  /// the prior SwiftUI `.onDrag` produced).
  private func snapshot() -> NSImage? {
    guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
    cacheDisplay(in: bounds, to: rep)
    let image = NSImage(size: bounds.size)
    image.addRepresentation(rep)
    return image
  }
}
