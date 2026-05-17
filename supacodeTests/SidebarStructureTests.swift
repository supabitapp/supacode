import ComposableArchitecture
import Foundation
import IdentifiedCollections
import OrderedCollections
import Sharing
import SwiftUI
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

/// Integration coverage for `RepositoriesFeature.State.computeSidebarStructure(...)`.
/// The pure helpers (`SidebarHighlightOrdering`, `SidebarActiveClassification`) have
/// their own unit suites; this file locks the contract on how they fuse — section
/// ordering, dedupe, hotkey numbering, placeholder mode, failed-repo positioning,
/// and the across-bucket dedupe inside `SidebarItemGroup.computeSlots`.
@MainActor
struct SidebarStructureTests {
  // MARK: - Helpers.

  private func makeWorktree(id: String, name: String, repoRoot: URL) -> Worktree {
    Worktree(
      id: id,
      name: name,
      detail: "",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: repoRoot
    )
  }

  private func makeMainWorktree(repoRoot: URL) -> Worktree {
    Worktree(
      id: repoRoot.path(percentEncoded: false),
      name: "main",
      detail: "",
      workingDirectory: repoRoot,
      repositoryRootURL: repoRoot
    )
  }

  private func makeState(repositories: [Repository]) -> RepositoriesFeature.State {
    var state = RepositoriesFeature.State(reconciledRepositories: repositories)
    state.isInitialLoadComplete = true
    return state
  }

  // MARK: - Placeholder mode.

  @Test func placeholderModeEmitsPlaceholderSectionAndEmptyHotkeys() {
    var state = RepositoriesFeature.State()
    state.isInitialLoadComplete = false
    state.repositories = []

    let structure = state.computeSidebarStructure(groupPinned: true, groupActive: true)

    #expect(structure.sections == [.placeholder])
    #expect(structure.hoistedRowIDs.isEmpty)
    #expect(structure.hotkeySlots.isEmpty)
    #expect(structure.slotByID.isEmpty)
    #expect(structure.repositoryHighlightByID.isEmpty)
    #expect(structure.reorderableRepositoryIDs.isEmpty)
  }

  // MARK: - Both toggles off → no hoisting.

  @Test func bothTogglesOffProducesNoHighlights() {
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")
    let main = makeMainWorktree(repoRoot: repoRoot)
    let wt = makeWorktree(id: "/tmp/repo/wt", name: "feature", repoRoot: repoRoot)
    let repository = Repository(
      id: repoRoot.path(percentEncoded: false),
      rootURL: repoRoot,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [main, wt])
    )
    let state = makeState(repositories: [repository])

    let structure = state.computeSidebarStructure(groupPinned: false, groupActive: false)

    let highlightKinds = structure.sections.compactMap { section -> SidebarStructure.HighlightKind? in
      if case .highlight(let kind, _) = section { return kind }
      return nil
    }
    #expect(highlightKinds.isEmpty)
    #expect(structure.hoistedRowIDs.isEmpty)
  }

  // MARK: - Pinned hoisting + git main exclusion.

  @Test func gitMainWorktreeNeverEntersPinnedHighlight() {
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")
    let main = makeMainWorktree(repoRoot: repoRoot)
    let repository = Repository(
      id: repoRoot.path(percentEncoded: false),
      rootURL: repoRoot,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [main])
    )
    var state = makeState(repositories: [repository])
    // Even if some pre-state has the main in `.pinned`, the helper must skip it.
    state.$sidebar.withLock { sidebar in
      var section = sidebar.sections[repository.id] ?? .init()
      var pinnedBucket = section.buckets[.pinned] ?? .init()
      pinnedBucket.items[main.id] = .init()
      section.buckets[.pinned] = pinnedBucket
      sidebar.sections[repository.id] = section
    }

    let structure = state.computeSidebarStructure(groupPinned: true, groupActive: true)

    let pinnedIDs = structure.sections.compactMap { section -> [Worktree.ID]? in
      if case .highlight(.pinned, let ids) = section { return ids }
      return nil
    }.flatMap { $0 }
    #expect(pinnedIDs.isEmpty)
    #expect(!structure.hoistedRowIDs.contains(main.id))
  }

  // MARK: - Hotkey order dedupes hoisted rows.

  @Test func hotkeyOrderDoesNotIncludeHoistedRowsTwice() {
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")
    let main = makeMainWorktree(repoRoot: repoRoot)
    let pinned = makeWorktree(id: "/tmp/repo/pinned", name: "pinned", repoRoot: repoRoot)
    let extra = makeWorktree(id: "/tmp/repo/extra", name: "extra", repoRoot: repoRoot)
    let repository = Repository(
      id: repoRoot.path(percentEncoded: false),
      rootURL: repoRoot,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [main, pinned, extra])
    )
    var state = makeState(repositories: [repository])
    // Pin `pinned` so it qualifies for the Pinned highlight section.
    state.$sidebar.withLock { sidebar in
      var section = sidebar.sections[repository.id] ?? .init()
      var pinnedBucket = section.buckets[.pinned] ?? .init()
      pinnedBucket.items[pinned.id] = .init()
      section.buckets[.pinned] = pinnedBucket
      sidebar.sections[repository.id] = section
    }

    let structure = state.computeSidebarStructure(groupPinned: true, groupActive: false)

    let hotkeyIDs = structure.hotkeySlots.map(\.id)
    #expect(hotkeyIDs.filter { $0 == pinned.id }.count == 1)
    #expect(structure.slotByID[pinned.id] != nil)
    // Pinned hoist appears before per-repo main in the visible top-down order.
    let pinnedSlot = structure.slotByID[pinned.id] ?? -1
    let mainSlot = structure.slotByID[main.id] ?? -1
    #expect(pinnedSlot < mainSlot)
  }

  // MARK: - Per-bucket dedupe (C9).

  @Test func computeSlotsDedupesAcrossPinnedAndUnpinnedBuckets() {
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")
    let main = makeMainWorktree(repoRoot: repoRoot)
    let duplicate = makeWorktree(id: "/tmp/repo/dup", name: "duplicate", repoRoot: repoRoot)
    let repository = Repository(
      id: repoRoot.path(percentEncoded: false),
      rootURL: repoRoot,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [main, duplicate])
    )
    var state = makeState(repositories: [repository])
    // Hand-edit pre-state so `duplicate` lives in BOTH .pinned and .unpinned.
    state.$sidebar.withLock { sidebar in
      var section = sidebar.sections[repository.id] ?? .init()
      var pinnedBucket = section.buckets[.pinned] ?? .init()
      pinnedBucket.items[duplicate.id] = .init()
      section.buckets[.pinned] = pinnedBucket
      var unpinnedBucket = section.buckets[.unpinned] ?? .init()
      unpinnedBucket.items[duplicate.id] = .init()
      section.buckets[.unpinned] = unpinnedBucket
      sidebar.sections[repository.id] = section
    }

    let groups = SidebarItemGroup.computeSlots(
      in: state,
      repositoryID: repository.id,
      pendingIDs: [],
      hoistedRowIDs: []
    )
    let allRowIDs = groups.flatMap { $0.rowIDs }
    #expect(allRowIDs.filter { $0 == duplicate.id }.count == 1)
  }

  // MARK: - Active classification.

  @Test func qualifyingRowsLandInActiveAndNotInPerRepoTail() {
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")
    let main = makeMainWorktree(repoRoot: repoRoot)
    let busy = makeWorktree(id: "/tmp/repo/busy", name: "busy", repoRoot: repoRoot)
    let idle = makeWorktree(id: "/tmp/repo/idle", name: "idle", repoRoot: repoRoot)
    let repository = Repository(
      id: repoRoot.path(percentEncoded: false),
      rootURL: repoRoot,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [main, busy, idle])
    )
    var state = makeState(repositories: [repository])
    // `runningScripts` non-empty is the simplest single flag that classifies
    // a row (unread alone returns nil — needs to be paired with another flag).
    state.sidebarItems[id: busy.id]?.runningScripts.append(.init(id: UUID(), tint: .blue))

    let structure = state.computeSidebarStructure(groupPinned: true, groupActive: true)

    let activeIDs = structure.sections.compactMap { section -> [Worktree.ID]? in
      if case .highlight(.active, let ids) = section { return ids }
      return nil
    }.flatMap { $0 }
    #expect(activeIDs == [busy.id])
    #expect(structure.hoistedRowIDs.contains(busy.id))
    // The hoisted row doesn't double-render in the repository section's tail.
    let perRepoTailIDs = structure.sections.compactMap { section -> [Worktree.ID]? in
      if case .repository(_, let groups) = section {
        return groups.flatMap(\.rowIDs)
      }
      return nil
    }.flatMap { $0 }
    #expect(!perRepoTailIDs.contains(busy.id))
  }

  // MARK: - Archived filter.

  @Test func archivedRowsExcludedFromBothHighlights() {
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")
    let main = makeMainWorktree(repoRoot: repoRoot)
    let archived = makeWorktree(id: "/tmp/repo/archived", name: "archived", repoRoot: repoRoot)
    let repository = Repository(
      id: repoRoot.path(percentEncoded: false),
      rootURL: repoRoot,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [main, archived])
    )
    var state = makeState(repositories: [repository])
    state.sidebarItems[id: archived.id]?.hasUnseenNotifications = true
    // Mark the row as archived; structure must skip it from both highlights.
    state.$sidebar.withLock { sidebar in
      var section = sidebar.sections[repository.id] ?? .init()
      var archivedBucket = section.buckets[.archived] ?? .init()
      archivedBucket.items[archived.id] = .init(archivedAt: Date(timeIntervalSince1970: 0))
      section.buckets[.archived] = archivedBucket
      sidebar.sections[repository.id] = section
    }

    let structure = state.computeSidebarStructure(groupPinned: true, groupActive: true)
    #expect(!structure.hoistedRowIDs.contains(archived.id))
  }

  // MARK: - Failed repository section placement.

  @Test func failedRepositorySectionEmittedAtRepositoryRootPosition() {
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")
    let main = makeMainWorktree(repoRoot: repoRoot)
    let repository = Repository(
      id: repoRoot.path(percentEncoded: false),
      rootURL: repoRoot,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [main])
    )
    var state = makeState(repositories: [repository])
    let failedRoot = URL(fileURLWithPath: "/tmp/broken")
    let failedID = failedRoot.path(percentEncoded: false)
    state.repositoryRoots.append(failedRoot)
    state.loadFailuresByID[failedID] = "boom"

    let structure = state.computeSidebarStructure(groupPinned: false, groupActive: false)

    let failedIndex = structure.sections.firstIndex {
      if case .failedRepository(let id, _, _) = $0 { return id == failedID }
      return false
    }
    let repoIndex = structure.sections.firstIndex {
      if case .repository(let id, _) = $0 { return id == repository.id }
      return false
    }
    #expect(failedIndex != nil)
    #expect(repoIndex != nil)
    #expect(structure.reorderableRepositoryIDs.contains(failedID))
  }

  // MARK: - Folder hoist drops the folder section.

  @Test func folderRowHoistedIntoHighlightIsOmittedFromItsFolderSection() {
    let folderURL = URL(fileURLWithPath: "/tmp/folder")
    let folderID = Repository.folderWorktreeID(for: folderURL)
    let folderRepo = Repository(
      id: folderURL.path(percentEncoded: false),
      rootURL: folderURL,
      name: "folder",
      worktrees: IdentifiedArray(
        uniqueElements: [
          Worktree(
            id: folderID,
            name: "folder",
            detail: "",
            workingDirectory: folderURL,
            repositoryRootURL: folderURL
          ),
        ]
      ),
      isGitRepository: false
    )
    var state = makeState(repositories: [folderRepo])
    state.$sidebar.withLock { sidebar in
      var section = sidebar.sections[folderRepo.id] ?? .init()
      var pinnedBucket = section.buckets[.pinned] ?? .init()
      pinnedBucket.items[folderID] = .init()
      section.buckets[.pinned] = pinnedBucket
      // Remove the default `.unpinned` seed so the row only lives in `.pinned`.
      section.buckets[.unpinned]?.items.removeValue(forKey: folderID)
      sidebar.sections[folderRepo.id] = section
    }

    let structure = state.computeSidebarStructure(groupPinned: true, groupActive: false)

    let hasFolderSection = structure.sections.contains {
      if case .folder(_, let id) = $0 { return id == folderID }
      return false
    }
    let pinnedIDs = structure.sections.compactMap { section -> [Worktree.ID]? in
      if case .highlight(.pinned, let ids) = section { return ids }
      return nil
    }.flatMap { $0 }
    #expect(pinnedIDs == [folderID])
    #expect(!hasFolderSection)
  }

  // MARK: - SidebarItemGroup.translateFilteredMove.

  @Test func translateFilteredMoveMapsAcrossHoistedRows() {
    let full = ["a", "b", "c", "d", "e"]
    let visible = ["a", "b", "d", "e"]  // c is hoisted.

    // Move visible offset 2 (d) to visible offset 0 (before a).
    let result = SidebarItemGroup.translateFilteredMove(
      offsets: IndexSet([2]),
      destination: 0,
      visibleIDs: visible,
      fullIDs: full
    )
    #expect(result?.offsets == IndexSet([3]))
    #expect(result?.destination == 0)
  }

  @Test func translateFilteredMoveDestinationPastEndMapsToFullEnd() {
    let full = ["a", "b", "c", "d"]
    let visible = ["a", "c", "d"]  // b is hoisted.

    let result = SidebarItemGroup.translateFilteredMove(
      offsets: IndexSet([0]),
      destination: visible.count,
      visibleIDs: visible,
      fullIDs: full
    )
    #expect(result?.offsets == IndexSet([0]))
    #expect(result?.destination == full.count)
  }

  @Test func translateFilteredMoveReturnsNilForOutOfRangeOffset() {
    let full = ["a", "b", "c"]
    let visible = ["a", "c"]

    let result = SidebarItemGroup.translateFilteredMove(
      offsets: IndexSet([5]),
      destination: 0,
      visibleIDs: visible,
      fullIDs: full
    )
    #expect(result == nil)
  }

  @Test func translateFilteredMoveReturnsNilForOutOfRangeDestination() {
    let full = ["a", "b", "c"]
    let visible = ["a", "c"]

    let result = SidebarItemGroup.translateFilteredMove(
      offsets: IndexSet([0]),
      destination: 99,
      visibleIDs: visible,
      fullIDs: full
    )
    #expect(result == nil)
  }

  @Test func translateFilteredMoveReturnsNilWhenVisibleHasIDNotInFull() {
    let full = ["a", "b"]
    let visible = ["a", "ghost"]  // "ghost" isn't in full.

    let result = SidebarItemGroup.translateFilteredMove(
      offsets: IndexSet([1]),
      destination: 0,
      visibleIDs: visible,
      fullIDs: full
    )
    #expect(result == nil)
  }

  @Test func translateFilteredMoveAppliedYieldsExpectedFullOrder() {
    let full = ["a", "b", "c", "d", "e"]
    let visible = ["a", "b", "d", "e"]  // c is hoisted.

    // Drag b (visible 1) past d (to before e, visible 3).
    let translated = SidebarItemGroup.translateFilteredMove(
      offsets: IndexSet([1]),
      destination: 3,
      visibleIDs: visible,
      fullIDs: full
    )
    #expect(translated != nil)
    guard let translated else { return }

    var reordered = full
    reordered.move(fromOffsets: translated.offsets, toOffset: translated.destination)
    // Hoisted c stays put relative to its neighbors; b lands before e.
    #expect(reordered == ["a", "c", "d", "b", "e"])
  }

  @Test func translateFilteredMoveHandlesEmptyOffsets() {
    let full = ["a", "b"]
    let visible = ["a", "b"]

    let result = SidebarItemGroup.translateFilteredMove(
      offsets: IndexSet(),
      destination: 1,
      visibleIDs: visible,
      fullIDs: full
    )
    #expect(result?.offsets == IndexSet())
    #expect(result?.destination == 1)
  }

  @Test func translateFilteredMoveLastVisibleIndexMapsBeforeHoistedTail() {
    // Inclusive upper-bound test: visible's last index (NOT past-end) when
    // followed by a hoisted tail row must map to its own full index, not the
    // full-end. Drops the dragged row before the hoisted tail, not after.
    let full = ["a", "b", "c", "d"]  // d is hoisted.
    let visible = ["a", "b", "c"]

    let translated = SidebarItemGroup.translateFilteredMove(
      offsets: IndexSet([0]),
      destination: visible.count - 1,
      visibleIDs: visible,
      fullIDs: full
    )
    #expect(translated != nil)
    guard let translated else { return }
    #expect(translated.offsets == IndexSet([0]))
    #expect(translated.destination == 2)

    var reordered = full
    reordered.move(fromOffsets: translated.offsets, toOffset: translated.destination)
    // Hoisted d stays last; a moves to just before c.
    #expect(reordered == ["b", "a", "c", "d"])
  }
}
