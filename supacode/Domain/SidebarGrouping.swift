import Foundation
import OrderedCollections

/// Render-order projection for `sidebarItems`. Rebuilt by `rebuildSidebarGrouping`; do not mutate directly.
struct SidebarGrouping: Equatable, Sendable {
  var bucketsByRepository: OrderedDictionary<Repository.ID, BucketGrouping> = [:]

  static let empty = SidebarGrouping()

  struct BucketGrouping: Equatable, Sendable {
    /// Every `SidebarBucket` case is pre-seeded so an empty bucket is structurally distinct from an absent one.
    var items: [SidebarBucket: [SidebarItemID]] = [
      .pinned: [],
      .unpinned: [],
      .archived: [],
    ]

    subscript(bucket: SidebarBucket) -> [SidebarItemID] {
      get { items[bucket] ?? [] }
      set { items[bucket] = newValue }
    }
  }
}

/// Decouples sidebar code from the persistence module's `SidebarState.BucketID`.
typealias SidebarBucket = SidebarState.BucketID
