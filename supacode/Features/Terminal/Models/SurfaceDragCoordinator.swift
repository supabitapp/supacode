import AppKit
import SupacodeSettingsShared
import UniformTypeIdentifiers

private let dragLogger = SupaLogger("SurfaceDrag")

/// Coordinates pane-rearrange drag-and-drop for one worktree's terminal area.
///
/// The rearrange machinery (drag handle + drop catcher) lives in a layer above
/// the split-tree leaves, so concrete `SurfaceView`s stay agnostic to it. This
/// object is the single piece of state that layer needs:
///
/// - The drag *source* (`SurfaceDragHandleView`) flips `draggingSourceID` via
///   `beginDrag`/`endDrag` from its `NSDraggingSource` callbacks. The view layer
///   observes `isDragging` to mount a `SurfaceDropCatcherView` over every visible
///   leaf only while a drag is in flight (and tear them down after — `endDrag`
///   always fires, including on cancel, which is why this is AppKit-driven and
///   not SwiftUI `.onDrag`, which has no end signal).
/// - The catcher reports a landed drop through `completeDrop`, which forwards to
///   `onDrop` (wired by `WorktreeTerminalState` to mutate the split tree).
@MainActor
@Observable
final class SurfaceDragCoordinator {
  /// The leaf currently being dragged by its handle, or `nil` when no rearrange
  /// drag is in flight.
  private(set) var draggingSourceID: UUID?

  /// True while a pane is being dragged — the view layer mounts catchers on this.
  var isDragging: Bool { draggingSourceID != nil }

  /// Set by the owner to perform the tree mutation once a drop lands. The catcher
  /// only knows ids + zone; the owner resolves the tab and rearranges.
  var onDrop: ((_ payloadID: UUID, _ destinationID: UUID, _ zone: TerminalSplitTreeView.DropZone) -> Void)?

  func beginDrag(sourceID: UUID) {
    dragLogger.debug("surfaceDrag willBegin id=\(sourceID)")
    draggingSourceID = sourceID
  }

  func endDrag() {
    guard draggingSourceID != nil else { return }
    dragLogger.debug("surfaceDrag ended")
    draggingSourceID = nil
  }

  func completeDrop(payloadID: UUID, destinationID: UUID, zone: TerminalSplitTreeView.DropZone) {
    dragLogger.debug("drop payload=\(payloadID) dest=\(destinationID) zone=\(zone.rawValue)")
    onDrop?(payloadID, destinationID, zone)
  }

  /// Reads the dragged leaf id from a rearrange drag's pasteboard. The handle
  /// writes the id as a plain string under `SurfaceView.surfaceDragType`, so this
  /// read is synchronous (no lazy item-provider promise). Pure — unit-tested.
  static func payloadID(from pasteboard: NSPasteboard) -> UUID? {
    guard
      let raw = pasteboard.string(forType: .init(SurfaceView.surfaceDragType.identifier))
    else { return nil }
    return UUID(uuidString: raw)
  }
}
