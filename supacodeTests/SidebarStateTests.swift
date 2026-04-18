import Foundation
import OrderedCollections
import Testing

@testable import supacode

@MainActor
struct SidebarStateTests {
  private let repoA = "/tmp/repo-a"
  private let repoB = "/tmp/repo-b"

  // MARK: - move

  @Test func movePreservesItemPayloadAcrossBuckets() {
    var state = SidebarState()
    state.insert(
      worktree: "wt-1",
      in: repoA,
      bucket: .unpinned,
      item: .init(archivedAt: nil)
    )

    state.move(worktree: "wt-1", in: repoA, from: .unpinned, to: .pinned, position: 0)

    #expect(state.sections[repoA]?.buckets[.unpinned]?.items.isEmpty == true)
    #expect(state.sections[repoA]?.buckets[.pinned]?.items["wt-1"] != nil)
  }

  @Test func moveClearsArchivedAtWhenLeavingArchived() {
    var state = SidebarState()
    state.insert(
      worktree: "wt-1",
      in: repoA,
      bucket: .archived,
      item: .init(archivedAt: Date(timeIntervalSince1970: 1_000_000))
    )

    state.move(worktree: "wt-1", in: repoA, from: .archived, to: .unpinned, position: 0)

    #expect(state.sections[repoA]?.buckets[.archived]?.items["wt-1"] == nil)
    #expect(state.sections[repoA]?.buckets[.unpinned]?.items["wt-1"]?.archivedAt == nil)
  }

  @Test func moveNoopWhenItemNotInSourceBucket() {
    var state = SidebarState()
    state.insert(worktree: "wt-1", in: repoA, bucket: .unpinned)

    // Source bucket is `.pinned`, but the item lives in `.unpinned`.
    state.move(worktree: "wt-1", in: repoA, from: .pinned, to: .archived, position: 0)

    #expect(state.sections[repoA]?.buckets[.unpinned]?.items["wt-1"] != nil)
    #expect(state.sections[repoA]?.buckets[.archived] == nil)
  }

  @Test func moveToSameBucketReordersToPosition() {
    var state = SidebarState()
    state.insert(worktree: "wt-1", in: repoA, bucket: .unpinned)
    state.insert(worktree: "wt-2", in: repoA, bucket: .unpinned)
    state.insert(worktree: "wt-3", in: repoA, bucket: .unpinned)

    // Bump wt-3 to the top of `.unpinned`.
    state.move(worktree: "wt-3", in: repoA, from: .unpinned, to: .unpinned, position: 0)

    let order = Array(state.sections[repoA]?.buckets[.unpinned]?.items.keys ?? [])
    #expect(order == ["wt-3", "wt-1", "wt-2"])
  }

  // MARK: - archive / unarchive

  @Test func archivePlacesWorktreeIntoArchivedBucketWithTimestamp() {
    var state = SidebarState()
    state.insert(worktree: "wt-1", in: repoA, bucket: .unpinned)
    let timestamp = Date(timeIntervalSince1970: 1_000_000)

    state.archive(worktree: "wt-1", in: repoA, from: .unpinned, at: timestamp)

    #expect(state.sections[repoA]?.buckets[.unpinned]?.items.isEmpty == true)
    #expect(state.sections[repoA]?.buckets[.archived]?.items["wt-1"]?.archivedAt == timestamp)
  }

  @Test func unarchiveRestoresToTopOfUnpinnedAndClearsTimestamp() {
    var state = SidebarState()
    state.insert(
      worktree: "wt-archived",
      in: repoA,
      bucket: .archived,
      item: .init(archivedAt: Date(timeIntervalSince1970: 1_000_000))
    )
    state.insert(worktree: "wt-live", in: repoA, bucket: .unpinned)

    state.unarchive(worktree: "wt-archived", in: repoA)

    #expect(state.sections[repoA]?.buckets[.archived]?.items.isEmpty == true)
    let unpinnedOrder = Array(state.sections[repoA]?.buckets[.unpinned]?.items.keys ?? [])
    #expect(unpinnedOrder == ["wt-archived", "wt-live"])
    #expect(state.sections[repoA]?.buckets[.unpinned]?.items["wt-archived"]?.archivedAt == nil)
  }

  // MARK: - remove

  @Test func removeDropsFromGivenBucketOnly() {
    var state = SidebarState()
    state.insert(worktree: "wt-1", in: repoA, bucket: .pinned)
    state.insert(worktree: "wt-1", in: repoA, bucket: .unpinned)

    state.remove(worktree: "wt-1", in: repoA, from: .pinned)

    #expect(state.sections[repoA]?.buckets[.pinned]?.items["wt-1"] == nil)
    #expect(state.sections[repoA]?.buckets[.unpinned]?.items["wt-1"] != nil)
  }

  // MARK: - reorder

  @Test func reorderPreservesPayloadsAndBucketScope() {
    var state = SidebarState()
    state.insert(worktree: "p-1", in: repoA, bucket: .pinned)
    state.insert(worktree: "p-2", in: repoA, bucket: .pinned)
    state.insert(worktree: "u-1", in: repoA, bucket: .unpinned)

    state.reorder(bucket: .pinned, in: repoA, to: ["p-2", "p-1"])

    let pinned = Array(state.sections[repoA]?.buckets[.pinned]?.items.keys ?? [])
    let unpinned = Array(state.sections[repoA]?.buckets[.unpinned]?.items.keys ?? [])
    #expect(pinned == ["p-2", "p-1"])
    #expect(unpinned == ["u-1"])
  }

  // MARK: - archivedWorktrees accessor

  @Test func archivedWorktreesEnumeratesAcrossSections() {
    var state = SidebarState()
    let t1 = Date(timeIntervalSince1970: 1_000_000)
    let t2 = Date(timeIntervalSince1970: 2_000_000)
    state.insert(
      worktree: "wt-a", in: repoA, bucket: .archived, item: .init(archivedAt: t1)
    )
    state.insert(
      worktree: "wt-b", in: repoB, bucket: .archived, item: .init(archivedAt: t2)
    )

    let archived = state.archivedWorktrees

    #expect(archived.count == 2)
    #expect(archived.contains { $0.worktreeID == "wt-a" && $0.archivedAt == t1 })
    #expect(archived.contains { $0.worktreeID == "wt-b" && $0.archivedAt == t2 })
  }

  // MARK: - Codable round-trip

  @Test func codableRoundTripPreservesNestedShape() throws {
    var original = SidebarState()
    original.focusedWorktreeID = "wt-focus"
    original.sections[repoA] = .init(collapsed: true)
    original.insert(worktree: "p-1", in: repoA, bucket: .pinned)
    original.insert(worktree: "u-1", in: repoA, bucket: .unpinned)
    original.insert(
      worktree: "a-1",
      in: repoA,
      bucket: .archived,
      item: .init(archivedAt: Date(timeIntervalSince1970: 1_000_000))
    )
    original.insert(worktree: "b-u-1", in: repoB, bucket: .unpinned)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(original)
    let decoded = try JSONDecoder().decode(SidebarState.self, from: data)

    #expect(decoded == original)
  }

  @Test func codableEmptyRoundTrip() throws {
    let original = SidebarState()
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(SidebarState.self, from: data)
    #expect(decoded == original)
  }

  @Test func onDiskBucketKeysAreStableWireFormat() throws {
    // Pins the literal bucket-id / item-field strings that
    // `sidebar.json` uses on disk. Renaming an enum case or a
    // Codable field without flipping the `rawValue` would silently
    // diverge the schema and break the migrator's idempotency,
    // since the file-existence gate would latch the new shape as
    // "already migrated" on every future launch.
    var state = SidebarState()
    state.sections[repoA] = .init(collapsed: true)
    state.insert(worktree: "wt-1", in: repoA, bucket: .pinned)
    state.insert(worktree: "wt-2", in: repoA, bucket: .unpinned)
    state.insert(
      worktree: "wt-3",
      in: repoA,
      bucket: .archived,
      item: .init(archivedAt: Date(timeIntervalSince1970: 1_000_000))
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(state)
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(json.contains("\"pinned\""))
    #expect(json.contains("\"unpinned\""))
    #expect(json.contains("\"archived\""))
    #expect(json.contains("\"archivedAt\""))
    #expect(json.contains("\"collapsed\""))
  }

  @Test func unarchiveRepeatedlyDoesNotLeakBuckets() {
    // Regression pin: calling `unarchive` on a worktree that was
    // never archived must be a no-op — the seed pass relies on
    // this invariant when it materialises default `.unpinned`
    // entries.
    var state = SidebarState()
    state.insert(worktree: "wt-1", in: repoA, bucket: .unpinned)

    state.unarchive(worktree: "wt-1", in: repoA)
    state.unarchive(worktree: "nonexistent", in: repoA)

    #expect(state.sections[repoA]?.buckets[.unpinned]?.items["wt-1"] != nil)
    #expect(state.sections[repoA]?.buckets[.archived] == nil)
  }

  @Test func currentBucketReportsMembershipAcrossBuckets() {
    var state = SidebarState()
    state.insert(worktree: "p", in: repoA, bucket: .pinned)
    state.insert(worktree: "u", in: repoA, bucket: .unpinned)
    state.insert(
      worktree: "a",
      in: repoA,
      bucket: .archived,
      item: .init(archivedAt: Date(timeIntervalSince1970: 1))
    )

    #expect(state.currentBucket(of: "p", in: repoA) == .pinned)
    #expect(state.currentBucket(of: "u", in: repoA) == .unpinned)
    #expect(state.currentBucket(of: "a", in: repoA) == .archived)
    #expect(state.currentBucket(of: "missing", in: repoA) == nil)
    #expect(state.currentBucket(of: "p", in: repoB) == nil)
  }

  @Test func removeAnywhereClearsEveryBucket() {
    var state = SidebarState()
    state.insert(worktree: "wt", in: repoA, bucket: .pinned)
    state.insert(worktree: "wt", in: repoA, bucket: .unpinned)
    state.insert(
      worktree: "wt",
      in: repoA,
      bucket: .archived,
      item: .init(archivedAt: Date(timeIntervalSince1970: 1))
    )

    state.removeAnywhere(worktree: "wt", in: repoA)

    #expect(state.sections[repoA]?.buckets[.pinned]?.items["wt"] == nil)
    #expect(state.sections[repoA]?.buckets[.unpinned]?.items["wt"] == nil)
    #expect(state.sections[repoA]?.buckets[.archived]?.items["wt"] == nil)
  }

  @Test func sectionCollapsedDefaultsToFalseWhenKeyIsAbsent() throws {
    // Legacy `sidebar.json` written before `collapsed` became
    // non-optional had no key for the default case. Decoding a
    // Section without the `collapsed` field must fall back to
    // `false` so those files still load cleanly.
    let json = Data("{}".utf8)
    let decoded = try JSONDecoder().decode(SidebarState.Section.self, from: json)
    #expect(decoded.collapsed == false)
    #expect(decoded.buckets.isEmpty)
  }
}
