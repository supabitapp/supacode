import Foundation

/// Origin of an in-progress cross-bucket sidebar drag.
/// Per-row drag highlight lives on `SidebarItemFeature.State.isDragging`.
struct DragSession: Equatable, Sendable {
  let originRepositoryID: Repository.ID
  let originBucket: SidebarBucket
  let itemIDs: Set<SidebarItemID>
}
