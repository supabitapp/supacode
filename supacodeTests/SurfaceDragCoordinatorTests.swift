import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import supacode

@MainActor
struct SurfaceDragCoordinatorTests {
  @Test func beginDragSetsInFlightState() {
    let coordinator = SurfaceDragCoordinator()
    let source = UUID()

    #expect(!coordinator.isDragging)
    coordinator.beginDrag(sourceID: source)
    #expect(coordinator.isDragging)
    #expect(coordinator.draggingSourceID == source)
  }

  @Test func endDragClearsState() {
    let coordinator = SurfaceDragCoordinator()
    coordinator.beginDrag(sourceID: UUID())

    coordinator.endDrag()
    #expect(!coordinator.isDragging)
    #expect(coordinator.draggingSourceID == nil)
  }

  // A cancelled drag (released over nothing / Escape) ends without a drop. The
  // AppKit source still fires `endedAt`, so `endDrag` must reset cleanly even
  // when no `completeDrop` happened — otherwise catchers would leak.
  @Test func endDragWithoutDropStillClears() {
    let coordinator = SurfaceDragCoordinator()
    var dropped = false
    coordinator.onDrop = { _, _, _ in dropped = true }

    coordinator.beginDrag(sourceID: UUID())
    coordinator.endDrag()

    #expect(!coordinator.isDragging)
    #expect(!dropped)
  }

  @Test func completeDropForwardsToOnDrop() {
    let coordinator = SurfaceDragCoordinator()
    let payload = UUID()
    let destination = UUID()
    var receivedPayload: UUID?
    var receivedDestination: UUID?
    var receivedZone: TerminalSplitTreeView.DropZone?
    coordinator.onDrop = { payloadID, destinationID, zone in
      receivedPayload = payloadID
      receivedDestination = destinationID
      receivedZone = zone
    }

    coordinator.completeDrop(payloadID: payload, destinationID: destination, zone: .right)

    #expect(receivedPayload == payload)
    #expect(receivedDestination == destination)
    #expect(receivedZone == .right)
  }

  @Test func payloadIDParsesSurfaceDragType() {
    let pasteboard = NSPasteboard.withUniqueName()
    let id = UUID()
    pasteboard.clearContents()
    pasteboard.setString(
      id.uuidString,
      forType: NSPasteboard.PasteboardType(SurfaceView.surfaceDragType.identifier))

    #expect(SurfaceDragCoordinator.payloadID(from: pasteboard) == id)
  }

  @Test func payloadIDIsNilForMissingOrGarbage() {
    let empty = NSPasteboard.withUniqueName()
    empty.clearContents()
    #expect(SurfaceDragCoordinator.payloadID(from: empty) == nil)

    let garbage = NSPasteboard.withUniqueName()
    garbage.clearContents()
    garbage.setString(
      "not-a-uuid",
      forType: NSPasteboard.PasteboardType(SurfaceView.surfaceDragType.identifier))
    #expect(SurfaceDragCoordinator.payloadID(from: garbage) == nil)
  }
}
