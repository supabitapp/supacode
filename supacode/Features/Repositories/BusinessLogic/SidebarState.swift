import Foundation
import OrderedCollections

/// User-curated sidebar state persisted to `~/.supacode/sidebar.json`.
///
/// The shape mirrors the rendered tree: the root holds sections (one
/// per repository row), each section holds buckets (pinned /
/// unpinned / archived), and each bucket holds items (one per
/// worktree row). Readers access everything via keyed lookup —
/// `sections[repo]?.buckets[.pinned]?.items[wt]` — so callers never
/// rely on bucket iteration order. `Item.archivedAt` is non-`nil`
/// only inside the `.archived` bucket; the mutating API clears it
/// when an item leaves `.archived`, so the field is a reliable "is
/// this currently archived?" signal without a separate bucket
/// check.
///
/// Mutations go through typed primitives that take full coordinates
/// — repo + worktree + source bucket — so every helper is O(1) by
/// construction and the sidebar stays the single source of truth for
/// pin/order/archive state. `move`, `insert`, `archive`, `unarchive`,
/// `remove`, `reorder` cover the full mutation surface; callers
/// always know the source bucket from their reducer context.
nonisolated struct SidebarState: Equatable, Sendable, Codable {
  var schemaVersion: Int
  var sections: OrderedDictionary<Repository.ID, Section>
  var focusedWorktreeID: Worktree.ID?

  /// Memberwise initializer. `schemaVersion` defaults to `0`, meaning
  /// "not migrated yet, or migrator failed". The boot-time migrator
  /// is the only writer that sets it to `1`; every other writer
  /// (including the default `SidebarState()` path and mutations
  /// persisted by `SidebarKey.save`) leaves it at `0`.
  init(
    schemaVersion: Int = 0,
    sections: OrderedDictionary<Repository.ID, Section> = [:],
    focusedWorktreeID: Worktree.ID? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.sections = sections
    self.focusedWorktreeID = focusedWorktreeID
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case sections
    case focusedWorktreeID
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // Default to `0` when the key is absent so existing
    // `sidebar.json` files written before `schemaVersion` existed
    // decode as "not migrated yet".
    self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
    self.sections =
      try container.decodeIfPresent(
        OrderedDictionary<Repository.ID, Section>.self,
        forKey: .sections
      ) ?? [:]
    self.focusedWorktreeID = try container.decodeIfPresent(Worktree.ID.self, forKey: .focusedWorktreeID)
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    // Always encode `schemaVersion` so the value round-trips and the
    // migrator can distinguish "written by migrator" from "written by
    // first-mutation after migrator failure".
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(sections, forKey: .sections)
    try container.encodeIfPresent(focusedWorktreeID, forKey: .focusedWorktreeID)
  }

  nonisolated enum BucketID: String, Codable, Hashable, Sendable {
    case pinned
    case unpinned
    case archived
  }

  nonisolated struct Section: Equatable, Sendable, Codable {
    var collapsed: Bool
    var buckets: OrderedDictionary<BucketID, Bucket>
    /// Optional user-supplied display title that overrides the
    /// repository folder name in the sidebar header. `nil` (or
    /// whitespace-only after trim) means "use the default name".
    var title: String?
    /// Optional user-supplied tint applied to the sidebar header.
    /// `nil` means "default / no tint".
    var color: RepositoryColor?

    init(
      collapsed: Bool = false,
      buckets: OrderedDictionary<BucketID, Bucket> = [:],
      title: String? = nil,
      color: RepositoryColor? = nil
    ) {
      self.collapsed = collapsed
      self.buckets = buckets
      self.title = title
      self.color = color
    }

    private enum SectionCodingKeys: String, CodingKey {
      case collapsed
      case buckets
      case title
      case color
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: SectionCodingKeys.self)
      // Default to `false` / empty when the key is absent so existing
      // `sidebar.json` files written before these fields became
      // non-optional still decode cleanly.
      self.collapsed = try container.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
      self.buckets =
        try container.decodeIfPresent(
          OrderedDictionary<BucketID, Bucket>.self,
          forKey: .buckets
        ) ?? [:]
      self.title = try container.decodeIfPresent(String.self, forKey: .title)
      self.color = try container.decodeIfPresent(RepositoryColor.self, forKey: .color)
    }

    func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: SectionCodingKeys.self)
      // Always encode `collapsed` and `buckets` so the wire format
      // stays exhaustive and the migrator can rely on a stable shape.
      try container.encode(collapsed, forKey: .collapsed)
      try container.encode(buckets, forKey: .buckets)
      // Customization fields are only emitted when set so the file
      // stays clean for repos the user never touched.
      try container.encodeIfPresent(title, forKey: .title)
      try container.encodeIfPresent(color, forKey: .color)
    }
  }

  nonisolated struct Bucket: Equatable, Sendable, Codable {
    var items: OrderedDictionary<Worktree.ID, Item> = [:]
  }

  nonisolated struct Item: Equatable, Sendable, Codable {
    /// Timestamp the worktree was archived at. Non-`nil` only inside
    /// the `.archived` bucket — the mutating API clears it when an
    /// item leaves `.archived`, so the field is a reliable "is this
    /// currently archived?" signal without a bucket check.
    var archivedAt: Date?
  }

  /// Flat reference to an archived worktree: the owning repo, the
  /// worktree ID, and the timestamp it was archived at. Used by the
  /// `archivedWorktrees` accessor so callers can consume the fan-out
  /// via property access rather than tuple destructuring.
  nonisolated struct ArchivedWorktreeRef: Equatable, Sendable {
    let repositoryID: Repository.ID
    let worktreeID: Worktree.ID
    let archivedAt: Date
  }
}

// MARK: - Read-side accessors.

nonisolated extension SidebarState {
  /// Flat view over every archived worktree across every section.
  /// The only reader that genuinely needs a fan-out iterator is the
  /// auto-delete sweep (and the archived-worktrees detail view),
  /// which can't know the owning repo up front. Every other reader
  /// should reach through `sections[repoID]?.buckets[bucket]?.items[wid]?`
  /// directly.
  ///
  /// Iteration follows `sections` insertion order, then item
  /// insertion order inside `.archived`.
  var archivedWorktrees: [ArchivedWorktreeRef] {
    var result: [ArchivedWorktreeRef] = []
    for (repoID, section) in sections {
      guard let archived = section.buckets[.archived] else {
        continue
      }
      for (worktreeID, item) in archived.items {
        if let archivedAt = item.archivedAt {
          result.append(
            ArchivedWorktreeRef(
              repositoryID: repoID,
              worktreeID: worktreeID,
              archivedAt: archivedAt
            )
          )
        }
      }
    }
    return result
  }

  /// Bucket that currently contains `worktreeID` in `repositoryID`,
  /// or `nil` when the worktree isn't curated in any bucket. Used
  /// by reducer actions that need to pass `from:` to `move` or
  /// `archive` but only know the repo + worktree from their action
  /// payload. O(buckets) = O(3); cheaper than any scan.
  func currentBucket(of worktreeID: Worktree.ID, in repositoryID: Repository.ID) -> BucketID? {
    guard let section = sections[repositoryID] else {
      return nil
    }
    for (bucketID, bucket) in section.buckets where bucket.items[worktreeID] != nil {
      return bucketID
    }
    return nil
  }
}

// MARK: - Mutations.

nonisolated extension SidebarState {
  /// Move `worktreeID` from `from` to `to` inside `repositoryID`,
  /// preserving the existing `Item` payload. Clears `archivedAt`
  /// when `to != .archived`. `position` is the insertion index
  /// inside `to` (default `0` = top of bucket; `nil` = append).
  /// No-op when the item isn't in `from`.
  mutating func move(
    worktree worktreeID: Worktree.ID,
    in repositoryID: Repository.ID,
    from: BucketID,
    to destination: BucketID,
    position: Int? = 0
  ) {
    guard var section = sections[repositoryID] else {
      return
    }
    guard var item = section.buckets[from]?.items.removeValue(forKey: worktreeID) else {
      return
    }
    if destination != .archived {
      item.archivedAt = nil
    }
    var bucket = section.buckets[destination] ?? .init()
    insert(item: item, for: worktreeID, into: &bucket, position: position)
    section.buckets[destination] = bucket
    sections[repositoryID] = section
  }

  /// Insert a fresh `Item` into the given bucket at `position`.
  /// Used by the reducer's seed pass when a newly-discovered live
  /// worktree first appears, so every rendered worktree has a
  /// bucketed entry by the time the view reads it.
  mutating func insert(
    worktree worktreeID: Worktree.ID,
    in repositoryID: Repository.ID,
    bucket bucketID: BucketID,
    item: Item = .init(),
    position: Int? = nil
  ) {
    var section = sections[repositoryID] ?? .init()
    var bucket = section.buckets[bucketID] ?? .init()
    insert(item: item, for: worktreeID, into: &bucket, position: position)
    section.buckets[bucketID] = bucket
    sections[repositoryID] = section
  }

  /// Archive `worktreeID`: drop from `from`, insert into `.archived`
  /// at the tail with the given timestamp. Materialises the section
  /// and the archived bucket when missing so a late-arriving
  /// archive action lands even if the pruner's seed pass hasn't
  /// run yet for this repo.
  mutating func archive(
    worktree worktreeID: Worktree.ID,
    in repositoryID: Repository.ID,
    from: BucketID,
    at timestamp: Date
  ) {
    var section = sections[repositoryID] ?? .init()
    section.buckets[from]?.items.removeValue(forKey: worktreeID)
    var archived = section.buckets[.archived] ?? .init()
    archived.items[worktreeID] = .init(archivedAt: timestamp)
    section.buckets[.archived] = archived
    sections[repositoryID] = section
  }

  /// Unarchive `worktreeID`: drop from `.archived` and reinsert at
  /// the top of `.unpinned`. Clears `archivedAt`. No-op when the
  /// worktree isn't currently archived in this section.
  mutating func unarchive(worktree worktreeID: Worktree.ID, in repositoryID: Repository.ID) {
    move(worktree: worktreeID, in: repositoryID, from: .archived, to: .unpinned, position: 0)
  }

  /// Remove `worktreeID` from `bucketID` of `repositoryID`.
  /// No-op when the section or bucket or worktree is absent. Used
  /// by callers that know the source bucket.
  mutating func remove(
    worktree worktreeID: Worktree.ID,
    in repositoryID: Repository.ID,
    from bucketID: BucketID
  ) {
    sections[repositoryID]?.buckets[bucketID]?.items.removeValue(forKey: worktreeID)
  }

  /// Remove `worktreeID` from every bucket of `repositoryID`. Used
  /// by the delete flow (the worktree is going away entirely, so
  /// we don't need to know which bucket currently owns it). O(1)
  /// — exactly three bucket subscripts, no scan.
  mutating func removeAnywhere(worktree worktreeID: Worktree.ID, in repositoryID: Repository.ID) {
    guard sections[repositoryID] != nil else {
      return
    }
    sections[repositoryID]?.buckets[.pinned]?.items.removeValue(forKey: worktreeID)
    sections[repositoryID]?.buckets[.unpinned]?.items.removeValue(forKey: worktreeID)
    sections[repositoryID]?.buckets[.archived]?.items.removeValue(forKey: worktreeID)
  }

  /// Reorder `bucketID`'s items in `repositoryID` to exactly
  /// `reorderedIDs`, preserving item payloads. Items in
  /// `reorderedIDs` that don't currently live in this bucket are
  /// ignored; items outside `reorderedIDs` keep their current
  /// relative position after the reordered run. Other buckets
  /// untouched.
  mutating func reorder(
    bucket bucketID: BucketID,
    in repositoryID: Repository.ID,
    to reorderedIDs: [Worktree.ID]
  ) {
    guard var section = sections[repositoryID], var bucket = section.buckets[bucketID] else {
      return
    }
    let reorderedSet = Set(reorderedIDs)
    var rebuilt: OrderedDictionary<Worktree.ID, Item> = [:]
    var reorderedInserted = false
    for (worktreeID, item) in bucket.items {
      if reorderedSet.contains(worktreeID) {
        if !reorderedInserted {
          for id in reorderedIDs {
            if let existing = bucket.items[id] {
              rebuilt[id] = existing
            }
          }
          reorderedInserted = true
        }
        continue
      }
      rebuilt[worktreeID] = item
    }
    if !reorderedInserted {
      for id in reorderedIDs {
        if let existing = bucket.items[id] {
          rebuilt[id] = existing
        }
      }
    }
    bucket.items = rebuilt
    section.buckets[bucketID] = bucket
    sections[repositoryID] = section
  }

  /// Shared insertion helper — clamps `position` to the current
  /// item count and falls back to append when `position` is `nil`
  /// or out of range.
  private func insert(
    item: Item,
    for worktreeID: Worktree.ID,
    into bucket: inout Bucket,
    position: Int?
  ) {
    if let position, position < bucket.items.count {
      bucket.items.updateValue(item, forKey: worktreeID, insertingAt: position)
    } else {
      bucket.items[worktreeID] = item
    }
  }
}
