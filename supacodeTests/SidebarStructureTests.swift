import ComposableArchitecture
import DependenciesTestSupport
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
/// their own unit suites; this file locks the contract on how they fuse: section
/// ordering, dedupe, hotkey numbering, placeholder mode, failed-repo positioning,
/// and the across-bucket dedupe inside `SidebarItemGroup.computeSlots`.
@MainActor
struct SidebarStructureTests {
  // MARK: - Helpers.

  private func makeWorktree(id: String, name: String, repoRoot: URL) -> Worktree {
    Worktree(
      id: WorktreeID(id),
      name: name,
      detail: "",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: repoRoot
    )
  }

  private func makeMainWorktree(repoRoot: URL) -> Worktree {
    Worktree(
      id: WorktreeID(repoRoot.path(percentEncoded: false)),
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
    let feature = makeWorktree(id: "/tmp/repo/wt", name: "feature", repoRoot: repoRoot)
    let repository = Repository(
      id: RepositoryID(repoRoot.path(percentEncoded: false)),
      rootURL: repoRoot,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [main, feature])
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
      id: RepositoryID(repoRoot.path(percentEncoded: false)),
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
      id: RepositoryID(repoRoot.path(percentEncoded: false)),
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

  // MARK: - Per-bucket dedupe.

  @Test func computeSlotsDedupesAcrossPinnedAndUnpinnedBuckets() {
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")
    let main = makeMainWorktree(repoRoot: repoRoot)
    let duplicate = makeWorktree(id: "/tmp/repo/dup", name: "duplicate", repoRoot: repoRoot)
    let repository = Repository(
      id: RepositoryID(repoRoot.path(percentEncoded: false)),
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
      hoistedRowIDs: [],
      nestWorktreesByBranch: false
    )
    let allRowIDs = groups.flatMap { $0.rowIDs }
    #expect(allRowIDs.filter { $0 == duplicate.id }.count == 1)
  }

  // MARK: - Archived rows re-enter while their delete script runs.

  @Test func computeSlotsSurfacesArchivedRowOnlyWhileDeleteScriptRuns() {
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")
    let main = makeMainWorktree(repoRoot: repoRoot)
    let archived = makeWorktree(id: "/tmp/repo/arch", name: "arch", repoRoot: repoRoot)
    let repository = Repository(
      id: RepositoryID(repoRoot.path(percentEncoded: false)),
      rootURL: repoRoot,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [main, archived])
    )
    var state = makeState(repositories: [repository])
    state.$sidebar.withLock { sidebar in
      var section = sidebar.sections[repository.id] ?? .init()
      section.buckets[.unpinned]?.items.removeValue(forKey: archived.id)
      var archivedBucket = section.buckets[.archived] ?? .init()
      archivedBucket.items[archived.id] = .init(archivedAt: .now)
      section.buckets[.archived] = archivedBucket
      sidebar.sections[repository.id] = section
    }
    state.reconcileSidebarForTesting()

    func unpinnedTail() -> [Worktree.ID] {
      SidebarItemGroup.computeSlots(
        in: state,
        repositoryID: repository.id,
        pendingIDs: [],
        hoistedRowIDs: [],
        nestWorktreesByBranch: false
      ).first { $0.slot == .unpinnedTail }?.rowIDs ?? []
    }

    // Idle archived row stays out of the main sidebar.
    #expect(!unpinnedTail().contains(archived.id))

    // Delete script running: the row re-enters the sidebar so the spinner /
    // terminal are reachable.
    state.sidebarItems[id: archived.id]?.lifecycle = .deletingScript
    #expect(unpinnedTail().contains(archived.id))

    // Completion or failure resets to idle: the row drops back to archived-only.
    state.sidebarItems[id: archived.id]?.lifecycle = .idle
    #expect(!unpinnedTail().contains(archived.id))
  }

  // MARK: - Branch nesting alphabetical sort.

  @Test func nestByBranchSortsPinnedAndUnpinnedTailsAlphabetically() {
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")
    let main = makeMainWorktree(repoRoot: repoRoot)
    let charlie = makeWorktree(id: "/tmp/repo/charlie", name: "charlie", repoRoot: repoRoot)
    let alpha = makeWorktree(id: "/tmp/repo/alpha", name: "alpha", repoRoot: repoRoot)
    let bravo = makeWorktree(id: "/tmp/repo/bravo", name: "bravo", repoRoot: repoRoot)
    let unpinX = makeWorktree(id: "/tmp/repo/x", name: "x-branch", repoRoot: repoRoot)
    let unpinB = makeWorktree(id: "/tmp/repo/b", name: "b-branch", repoRoot: repoRoot)
    let repository = Repository(
      id: RepositoryID(repoRoot.path(percentEncoded: false)),
      rootURL: repoRoot,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [main, charlie, alpha, bravo, unpinB, unpinX])
    )
    var state = makeState(repositories: [repository])
    // Pin charlie, alpha, bravo in bucket order DIFFERENT from alphabetical.
    state.$sidebar.withLock { sidebar in
      var section = sidebar.sections[repository.id] ?? .init()
      var pinnedBucket = section.buckets[.pinned] ?? .init()
      pinnedBucket.items[charlie.id] = .init()
      pinnedBucket.items[alpha.id] = .init()
      pinnedBucket.items[bravo.id] = .init()
      section.buckets[.pinned] = pinnedBucket
      var unpinnedBucket = section.buckets[.unpinned] ?? .init()
      unpinnedBucket.items.removeValue(forKey: charlie.id)
      unpinnedBucket.items.removeValue(forKey: alpha.id)
      unpinnedBucket.items.removeValue(forKey: bravo.id)
      section.buckets[.unpinned] = unpinnedBucket
      sidebar.sections[repository.id] = section
    }
    for id in [alpha.id, bravo.id, charlie.id, unpinX.id, unpinB.id] {
      let name = state.sidebarItems[id: id]?.name ?? id.rawValue
      state.sidebarItems[id: id]?.branchName = name
    }
    state.reconcileSidebarForTesting()

    let groups = SidebarItemGroup.computeSlots(
      in: state,
      repositoryID: repository.id,
      pendingIDs: [],
      hoistedRowIDs: [],
      nestWorktreesByBranch: true
    )

    let pinnedTail = groups.first { $0.slot == .pinnedTail }?.rowIDs ?? []
    let unpinnedTail = groups.first { $0.slot == .unpinnedTail }?.rowIDs ?? []
    #expect(pinnedTail == [alpha.id, bravo.id, charlie.id])
    #expect(unpinnedTail == [unpinB.id, unpinX.id])
  }

  @Test func nestByBranchOffPreservesBucketOrder() {
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")
    let main = makeMainWorktree(repoRoot: repoRoot)
    let charlie = makeWorktree(id: "/tmp/repo/charlie", name: "charlie", repoRoot: repoRoot)
    let alpha = makeWorktree(id: "/tmp/repo/alpha", name: "alpha", repoRoot: repoRoot)
    let repository = Repository(
      id: RepositoryID(repoRoot.path(percentEncoded: false)),
      rootURL: repoRoot,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [main, charlie, alpha])
    )
    var state = makeState(repositories: [repository])
    state.$sidebar.withLock { sidebar in
      var section = sidebar.sections[repository.id] ?? .init()
      var pinnedBucket = section.buckets[.pinned] ?? .init()
      pinnedBucket.items[charlie.id] = .init()
      pinnedBucket.items[alpha.id] = .init()
      section.buckets[.pinned] = pinnedBucket
      var unpinnedBucket = section.buckets[.unpinned] ?? .init()
      unpinnedBucket.items.removeValue(forKey: charlie.id)
      unpinnedBucket.items.removeValue(forKey: alpha.id)
      section.buckets[.unpinned] = unpinnedBucket
      sidebar.sections[repository.id] = section
    }
    state.reconcileSidebarForTesting()

    let groups = SidebarItemGroup.computeSlots(
      in: state,
      repositoryID: repository.id,
      pendingIDs: [],
      hoistedRowIDs: [],
      nestWorktreesByBranch: false
    )
    let pinnedTail = groups.first { $0.slot == .pinnedTail }?.rowIDs ?? []
    #expect(pinnedTail == [charlie.id, alpha.id])
  }

  @Test func hotkeySlotsFollowAlphabeticalOrderWhenNestByBranchOn() {
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")
    let main = makeMainWorktree(repoRoot: repoRoot)
    let charlie = makeWorktree(id: "/tmp/repo/charlie", name: "charlie", repoRoot: repoRoot)
    let alpha = makeWorktree(id: "/tmp/repo/alpha", name: "alpha", repoRoot: repoRoot)
    let bravo = makeWorktree(id: "/tmp/repo/bravo", name: "bravo", repoRoot: repoRoot)
    let repository = Repository(
      id: RepositoryID(repoRoot.path(percentEncoded: false)),
      rootURL: repoRoot,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [main, charlie, alpha, bravo])
    )
    var state = makeState(repositories: [repository])
    state.$sidebar.withLock { sidebar in
      var section = sidebar.sections[repository.id] ?? .init()
      var pinnedBucket = section.buckets[.pinned] ?? .init()
      pinnedBucket.items[charlie.id] = .init()
      pinnedBucket.items[alpha.id] = .init()
      pinnedBucket.items[bravo.id] = .init()
      section.buckets[.pinned] = pinnedBucket
      var unpinnedBucket = section.buckets[.unpinned] ?? .init()
      unpinnedBucket.items.removeValue(forKey: charlie.id)
      unpinnedBucket.items.removeValue(forKey: alpha.id)
      unpinnedBucket.items.removeValue(forKey: bravo.id)
      section.buckets[.unpinned] = unpinnedBucket
      sidebar.sections[repository.id] = section
    }
    for id in [alpha.id, bravo.id, charlie.id] {
      let name = state.sidebarItems[id: id]?.name ?? id.rawValue
      state.sidebarItems[id: id]?.branchName = name
    }
    state.$sidebarNestWorktreesByBranch.withLock { $0 = true }
    state.reconcileSidebarForTesting()

    let structure = state.computeSidebarStructure(groupPinned: false, groupActive: false)

    let expectedOrderAfterMain = [alpha.id, bravo.id, charlie.id]
    let mainSlot = structure.slotByID[main.id]
    let alphaSlot = structure.slotByID[alpha.id]
    let bravoSlot = structure.slotByID[bravo.id]
    let charlieSlot = structure.slotByID[charlie.id]
    #expect(mainSlot == 0)
    #expect(alphaSlot == 1)
    #expect(bravoSlot == 2)
    #expect(charlieSlot == 3)
    #expect(structure.hotkeySlots.map(\.id) == [main.id] + expectedOrderAfterMain)
  }

  // MARK: - Active classification.

  @Test func qualifyingRowsLandInActiveAndNotInPerRepoTail() {
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")
    let main = makeMainWorktree(repoRoot: repoRoot)
    let busy = makeWorktree(id: "/tmp/repo/busy", name: "busy", repoRoot: repoRoot)
    let idle = makeWorktree(id: "/tmp/repo/idle", name: "idle", repoRoot: repoRoot)
    let repository = Repository(
      id: RepositoryID(repoRoot.path(percentEncoded: false)),
      rootURL: repoRoot,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [main, busy, idle])
    )
    var state = makeState(repositories: [repository])
    // `runningScripts` non-empty is the simplest single flag that classifies
    // a row (unread alone returns nil, needs to be paired with another flag).
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

  private func activeIDs(in structure: SidebarStructure) -> [Worktree.ID] {
    structure.sections.compactMap { section -> [Worktree.ID]? in
      if case .highlight(.active, let ids) = section { return ids }
      return nil
    }.flatMap { $0 }
  }

  @Test func activeSectionSortsAlphabeticallyRegardlessOfClassification() {
    // #678: agent state (errored / awaiting / running) must not drive order.
    // An errored row no longer floats to the top; every row sorts by name.
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")
    let main = makeMainWorktree(repoRoot: repoRoot)
    let charlie = makeWorktree(id: "/tmp/repo/charlie", name: "charlie", repoRoot: repoRoot)
    let alpha = makeWorktree(id: "/tmp/repo/alpha", name: "alpha", repoRoot: repoRoot)
    let bravo = makeWorktree(id: "/tmp/repo/bravo", name: "bravo", repoRoot: repoRoot)
    let repository = Repository(
      id: RepositoryID(repoRoot.path(percentEncoded: false)),
      rootURL: repoRoot,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [main, charlie, alpha, bravo])
    )
    var state = makeState(repositories: [repository])
    // Three distinct classifications whose priority order (errored, agent,
    // running) is the reverse of alphabetical, proving classification no longer
    // drives order.
    state.sidebarItems[id: charlie.id]?.agentSnapshot.hasError = true
    state.sidebarItems[id: bravo.id]?.agentSnapshot.agents = [.init(agent: .claude, activity: .idle)]
    state.sidebarItems[id: alpha.id]?.runningScripts.append(.init(id: UUID(), tint: .blue))

    let structure = state.computeSidebarStructure(groupPinned: false, groupActive: true)
    #expect(activeIDs(in: structure) == [alpha.id, bravo.id, charlie.id])
  }

  @Test func unreadRowFloatsToTopOfActiveOnlyWhenPrioritized() {
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")
    let main = makeMainWorktree(repoRoot: repoRoot)
    let alpha = makeWorktree(id: "/tmp/repo/alpha", name: "alpha", repoRoot: repoRoot)
    let bravo = makeWorktree(id: "/tmp/repo/bravo", name: "bravo", repoRoot: repoRoot)
    let zulu = makeWorktree(id: "/tmp/repo/zulu", name: "zulu", repoRoot: repoRoot)
    let repository = Repository(
      id: RepositoryID(repoRoot.path(percentEncoded: false)),
      rootURL: repoRoot,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [main, alpha, bravo, zulu])
    )
    var state = makeState(repositories: [repository])
    // Every row classifies into Active via a running script; zulu is also unread.
    for id in [alpha.id, bravo.id, zulu.id] {
      state.sidebarItems[id: id]?.runningScripts.append(.init(id: UUID(), tint: .blue))
    }
    state.sidebarItems[id: zulu.id]?.hasUnseenNotifications = true

    state.moveNotifiedWorktreeToTop = false
    #expect(
      activeIDs(in: state.computeSidebarStructure(groupPinned: false, groupActive: true))
        == [alpha.id, bravo.id, zulu.id]
    )

    state.moveNotifiedWorktreeToTop = true
    #expect(
      activeIDs(in: state.computeSidebarStructure(groupPinned: false, groupActive: true))
        == [zulu.id, alpha.id, bravo.id]
    )
  }

  // MARK: - Archived filter.

  @Test func archivedRowsExcludedFromBothHighlights() {
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")
    let main = makeMainWorktree(repoRoot: repoRoot)
    let archived = makeWorktree(id: "/tmp/repo/archived", name: "archived", repoRoot: repoRoot)
    let repository = Repository(
      id: RepositoryID(repoRoot.path(percentEncoded: false)),
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
      id: RepositoryID(repoRoot.path(percentEncoded: false)),
      rootURL: repoRoot,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [main])
    )
    var state = makeState(repositories: [repository])
    let failedRoot = URL(fileURLWithPath: "/tmp/broken")
    let failedID = RepositoryID(failedRoot.path(percentEncoded: false))
    state.repositoryRoots.append(failedRoot)
    state.loadFailuresByID[failedID] = "boom"

    let structure = state.computeSidebarStructure(groupPinned: false, groupActive: false)

    let failedIndex = structure.sections.firstIndex {
      if case .failedRepository(let id, _, _, _, _) = $0 { return id == failedID }
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

  // MARK: - Environment-blocked git repos.

  @Test func environmentBlockedGitRootRendersWarningRowNotFailedRow() {
    // A git root we couldn't list because git is blocked stays visible as a
    // warning row (not removed, not a "broken" failure row).
    var state = makeState(repositories: [])
    let gitRoot = URL(fileURLWithPath: "/tmp/blocked-repo")
    let gitID = RepositoryID(gitRoot.path(percentEncoded: false))
    state.repositoryRoots.append(gitRoot)
    state.gitEnvironmentError = .xcodeLicenseNotAccepted

    let structure = state.computeSidebarStructure(groupPinned: false, groupActive: false)

    #expect(
      structure.sections.contains {
        if case .environmentBlockedRepository(let id, _, _, _) = $0 { return id == gitID }
        return false
      })
    #expect(
      !structure.sections.contains {
        if case .failedRepository(let id, _, _, _, _) = $0 { return id == gitID }
        return false
      })
    #expect(structure.reorderableRepositoryIDs.contains(gitID))
  }

  @Test func unloadedGitRootShowsNoWarningRowWhenGitHealthy() {
    // Without the gate set, an unloaded root is "still loading", not blocked.
    var state = makeState(repositories: [])
    state.repositoryRoots.append(URL(fileURLWithPath: "/tmp/loading-repo"))

    let structure = state.computeSidebarStructure(groupPinned: false, groupActive: false)

    #expect(
      !structure.sections.contains {
        if case .environmentBlockedRepository = $0 { return true }
        return false
      })
  }

  @Test func genuinelyFailedRepoStaysFailedRowEvenWhileGitBlocked() {
    // A missing directory is detectable without git, so it keeps its actionable
    // failure row rather than being masked as merely blocked.
    var state = makeState(repositories: [])
    let failedRoot = URL(fileURLWithPath: "/tmp/missing-dir")
    let failedID = RepositoryID(failedRoot.path(percentEncoded: false))
    state.repositoryRoots.append(failedRoot)
    state.loadFailuresByID[failedID] = "directory not found"
    state.gitEnvironmentError = .xcodeLicenseNotAccepted

    let structure = state.computeSidebarStructure(groupPinned: false, groupActive: false)

    #expect(
      structure.sections.contains {
        if case .failedRepository(let id, _, _, _, _) = $0 { return id == failedID }
        return false
      })
    #expect(
      !structure.sections.contains {
        if case .environmentBlockedRepository(let id, _, _, _) = $0 { return id == failedID }
        return false
      })
  }

  @Test func environmentBlockedRepositoryIDsListsBlockedRootsOnly() {
    // The set that both the warning rows and the terminal-prune shield read from.
    var state = makeState(repositories: [])
    let gitRoot = URL(fileURLWithPath: "/tmp/blocked-repo")
    let gitID = RepositoryID(gitRoot.path(percentEncoded: false))
    state.repositoryRoots.append(gitRoot)

    // Healthy: no gate, so nothing is blocked.
    #expect(state.environmentBlockedRepositoryIDs.isEmpty)

    state.gitEnvironmentError = .xcodeLicenseNotAccepted
    #expect(state.environmentBlockedRepositoryIDs == [gitID])

    // A failure entry means the repo is broken, not merely blocked.
    state.loadFailuresByID[gitID] = "boom"
    #expect(state.environmentBlockedRepositoryIDs.isEmpty)
  }

  // MARK: - Custom repo title flows through to the highlight tag.

  @Test func highlightTagReadsCustomRepoTitleAndColor() {
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")
    let main = makeMainWorktree(repoRoot: repoRoot)
    let busy = makeWorktree(id: "/tmp/repo/busy", name: "busy", repoRoot: repoRoot)
    let repository = Repository(
      id: RepositoryID(repoRoot.path(percentEncoded: false)),
      rootURL: repoRoot,
      name: "raw-folder-name",
      worktrees: IdentifiedArray(uniqueElements: [main, busy])
    )
    var state = makeState(repositories: [repository])
    state.sidebarItems[id: busy.id]?.runningScripts.append(.init(id: UUID(), tint: .blue))
    state.$sidebar.withLock { sidebar in
      sidebar.sections[repository.id, default: .init()].title = "  Pretty Name  "
      sidebar.sections[repository.id, default: .init()].color = .purple
    }

    let structure = state.computeSidebarStructure(groupPinned: true, groupActive: true)

    let tag = structure.repositoryHighlightByID[repository.id]
    #expect(tag?.repoName == "Pretty Name")
    #expect(tag?.repoColor == .purple)
  }

  @Test func highlightTagFallsBackToRepositoryNameOnEmptyCustomTitle() {
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")
    let main = makeMainWorktree(repoRoot: repoRoot)
    let busy = makeWorktree(id: "/tmp/repo/busy", name: "busy", repoRoot: repoRoot)
    let repository = Repository(
      id: RepositoryID(repoRoot.path(percentEncoded: false)),
      rootURL: repoRoot,
      name: "fallback-name",
      worktrees: IdentifiedArray(uniqueElements: [main, busy])
    )
    var state = makeState(repositories: [repository])
    state.sidebarItems[id: busy.id]?.runningScripts.append(.init(id: UUID(), tint: .blue))
    state.$sidebar.withLock { sidebar in
      sidebar.sections[repository.id, default: .init()].title = "   "
    }

    let structure = state.computeSidebarStructure(groupPinned: true, groupActive: true)

    #expect(structure.repositoryHighlightByID[repository.id]?.repoName == "fallback-name")
  }

  // MARK: - Lifecycle filter excludes terminating rows from Active.

  @Test func archivingRowIsExcludedFromActive() {
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")
    let main = makeMainWorktree(repoRoot: repoRoot)
    let archiving = makeWorktree(id: "/tmp/repo/archiving", name: "archiving", repoRoot: repoRoot)
    let repository = Repository(
      id: RepositoryID(repoRoot.path(percentEncoded: false)),
      rootURL: repoRoot,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [main, archiving])
    )
    var state = makeState(repositories: [repository])
    state.sidebarItems[id: archiving.id]?.runningScripts.append(.init(id: UUID(), tint: .blue))
    state.sidebarItems[id: archiving.id]?.lifecycle = .archiving

    let structure = state.computeSidebarStructure(groupPinned: true, groupActive: true)

    let activeIDs = structure.sections.compactMap { section -> [Worktree.ID]? in
      if case .highlight(.active, let ids) = section { return ids }
      return nil
    }.flatMap { $0 }
    #expect(!activeIDs.contains(archiving.id))
    #expect(!structure.hoistedRowIDs.contains(archiving.id))
  }

  @Test func deletingRowIsExcludedFromActive() {
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")
    let main = makeMainWorktree(repoRoot: repoRoot)
    let deleting = makeWorktree(id: "/tmp/repo/deleting", name: "deleting", repoRoot: repoRoot)
    let repository = Repository(
      id: RepositoryID(repoRoot.path(percentEncoded: false)),
      rootURL: repoRoot,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [main, deleting])
    )
    var state = makeState(repositories: [repository])
    state.sidebarItems[id: deleting.id]?.runningScripts.append(.init(id: UUID(), tint: .blue))
    state.sidebarItems[id: deleting.id]?.lifecycle = .deleting

    let structure = state.computeSidebarStructure(groupPinned: true, groupActive: true)

    let activeIDs = structure.sections.compactMap { section -> [Worktree.ID]? in
      if case .highlight(.active, let ids) = section { return ids }
      return nil
    }.flatMap { $0 }
    #expect(!activeIDs.contains(deleting.id))
  }

  @Test func pendingRowWithRunningScriptStaysEligibleForActive() {
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")
    let main = makeMainWorktree(repoRoot: repoRoot)
    let pending = makeWorktree(id: "/tmp/repo/pending", name: "pending", repoRoot: repoRoot)
    let repository = Repository(
      id: RepositoryID(repoRoot.path(percentEncoded: false)),
      rootURL: repoRoot,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [main, pending])
    )
    var state = makeState(repositories: [repository])
    state.sidebarItems[id: pending.id]?.runningScripts.append(.init(id: UUID(), tint: .blue))
    state.sidebarItems[id: pending.id]?.lifecycle = .pending

    let structure = state.computeSidebarStructure(groupPinned: true, groupActive: true)

    let activeIDs = structure.sections.compactMap { section -> [Worktree.ID]? in
      if case .highlight(.active, let ids) = section { return ids }
      return nil
    }.flatMap { $0 }
    #expect(activeIDs.contains(pending.id))
  }

  // MARK: - Git main detected at any pinned-bucket position.

  @Test func gitMainAtNonZeroPinnedIndexStillRoutesToMainSlot() {
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")
    let main = makeMainWorktree(repoRoot: repoRoot)
    let other = makeWorktree(id: "/tmp/repo/other", name: "other", repoRoot: repoRoot)
    let repository = Repository(
      id: RepositoryID(repoRoot.path(percentEncoded: false)),
      rootURL: repoRoot,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [main, other])
    )
    var state = makeState(repositories: [repository])
    // Corrupted pre-state: main lives at index 1 of `.pinned`, not 0. We
    // bypass `rebuildSidebarGrouping` (which would re-seed main at index 0)
    // by writing directly to `state.sidebarGrouping`.
    var bucket = SidebarGrouping.BucketGrouping()
    bucket[.pinned] = [other.id, main.id]
    bucket[.unpinned] = []
    bucket[.archived] = []
    state.sidebarGrouping = SidebarGrouping(bucketsByRepository: [repository.id: bucket])

    let groups = SidebarItemGroup.computeSlots(
      in: state,
      repositoryID: repository.id,
      pendingIDs: [],
      hoistedRowIDs: [],
      nestWorktreesByBranch: false
    )
    let mainGroup = groups.first { if case .main = $0.slot { return true } else { return false } }
    let pinnedTail = groups.first { if case .pinnedTail = $0.slot { return true } else { return false } }
    #expect(mainGroup?.rowIDs == [main.id])
    #expect(pinnedTail?.rowIDs == [other.id])
  }

  // MARK: - Folder hoist drops the folder section.

  @Test func folderRowHoistedIntoHighlightIsOmittedFromItsFolderSection() {
    let folderURL = URL(fileURLWithPath: "/tmp/folder")
    let folderID = Repository.folderWorktreeID(for: folderURL)
    let folderRepo = Repository(
      id: RepositoryID(folderURL.path(percentEncoded: false)),
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
          )
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

  // MARK: - Hoist summary.

  @Test func hoistSummaryCountsPinnedAndActiveWithPinnedFirstTarget() {
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")
    let main = makeMainWorktree(repoRoot: repoRoot)
    let pinned = makeWorktree(id: "/tmp/repo/pinned", name: "pinned", repoRoot: repoRoot)
    let busy = makeWorktree(id: "/tmp/repo/busy", name: "busy", repoRoot: repoRoot)
    let repository = Repository(
      id: RepositoryID(repoRoot.path(percentEncoded: false)),
      rootURL: repoRoot,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [main, pinned, busy])
    )
    var state = makeState(repositories: [repository])
    state.$sidebar.withLock { sidebar in
      var section = sidebar.sections[repository.id] ?? .init()
      var pinnedBucket = section.buckets[.pinned] ?? .init()
      pinnedBucket.items[pinned.id] = .init()
      section.buckets[.pinned] = pinnedBucket
      sidebar.sections[repository.id] = section
    }
    state.sidebarItems[id: busy.id]?.runningScripts.append(.init(id: UUID(), tint: .blue))

    let structure = state.computeSidebarStructure(groupPinned: true, groupActive: true)

    let summary = structure.hoistSummaryByRepositoryID[repository.id]
    #expect(summary?.pinnedCount == 1)
    #expect(summary?.activeCount == 1)
    // Pinned-first: the click target is the pinned hoist, not the active one.
    #expect(summary?.revealTarget == pinned.id)
    #expect(summary?.label == "+1 pinned, +1 active")
  }

  @Test func hoistSummaryFallsBackToActiveTargetWhenNoPinned() {
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")
    let main = makeMainWorktree(repoRoot: repoRoot)
    let busy = makeWorktree(id: "/tmp/repo/busy", name: "busy", repoRoot: repoRoot)
    let repository = Repository(
      id: RepositoryID(repoRoot.path(percentEncoded: false)),
      rootURL: repoRoot,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [main, busy])
    )
    var state = makeState(repositories: [repository])
    state.sidebarItems[id: busy.id]?.runningScripts.append(.init(id: UUID(), tint: .blue))

    let structure = state.computeSidebarStructure(groupPinned: true, groupActive: true)

    let summary = structure.hoistSummaryByRepositoryID[repository.id]
    #expect(summary?.pinnedCount == 0)
    #expect(summary?.activeCount == 1)
    #expect(summary?.revealTarget == busy.id)
    #expect(summary?.label == "+1 active")
  }

  @Test func hoistSummaryOmittedForRepoWithNoHoists() {
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")
    let main = makeMainWorktree(repoRoot: repoRoot)
    let idle = makeWorktree(id: "/tmp/repo/idle", name: "idle", repoRoot: repoRoot)
    let repository = Repository(
      id: RepositoryID(repoRoot.path(percentEncoded: false)),
      rootURL: repoRoot,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [main, idle])
    )
    let state = makeState(repositories: [repository])

    let structure = state.computeSidebarStructure(groupPinned: true, groupActive: true)

    #expect(structure.hoistSummaryByRepositoryID[repository.id] == nil)
  }

  @Test func hoistSummaryExcludesFolders() {
    let folderURL = URL(fileURLWithPath: "/tmp/folder")
    let folderID = Repository.folderWorktreeID(for: folderURL)
    let folderRepo = Repository(
      id: RepositoryID(folderURL.path(percentEncoded: false)),
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
          )
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
      section.buckets[.unpinned]?.items.removeValue(forKey: folderID)
      sidebar.sections[folderRepo.id] = section
    }

    let structure = state.computeSidebarStructure(groupPinned: true, groupActive: false)

    // The folder row is hoisted (so it carries a highlight tag) but a single-row
    // folder gets no summary: its row stays fully visible at the top.
    #expect(structure.hoistedRowIDs.contains(folderID))
    #expect(structure.hoistSummaryByRepositoryID[folderRepo.id] == nil)
  }

  @Test func hoistSummaryCountsGitMainHoistedIntoActive() {
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")
    let main = makeMainWorktree(repoRoot: repoRoot)
    let repository = Repository(
      id: RepositoryID(repoRoot.path(percentEncoded: false)),
      rootURL: repoRoot,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [main])
    )
    var state = makeState(repositories: [repository])
    state.sidebarItems[id: main.id]?.runningScripts.append(.init(id: UUID(), tint: .blue))

    let structure = state.computeSidebarStructure(groupPinned: true, groupActive: true)

    let summary = structure.hoistSummaryByRepositoryID[repository.id]
    #expect(summary?.activeCount == 1)
    #expect(summary?.pinnedCount == 0)
    #expect(summary?.revealTarget == main.id)
    // The repository section is still emitted (header + summary line), with no
    // per-repo rows since main was hoisted.
    let repoGroups = structure.sections.compactMap { section -> [SidebarItemGroup]? in
      if case .repository(let id, let groups) = section, id == repository.id { return groups }
      return nil
    }.flatMap { $0 }
    #expect(repoGroups.allSatisfy { $0.rowIDs.isEmpty })
  }

  @Test func hoistSummaryKeepsEachRepoTallyIndependent() {
    let rootA = URL(fileURLWithPath: "/tmp/repo-a")
    let rootB = URL(fileURLWithPath: "/tmp/repo-b")
    let mainA = makeMainWorktree(repoRoot: rootA)
    let mainB = makeMainWorktree(repoRoot: rootB)
    let pinnedA = makeWorktree(id: "/tmp/repo-a/p", name: "pa", repoRoot: rootA)
    let pinnedB = makeWorktree(id: "/tmp/repo-b/p", name: "pb", repoRoot: rootB)
    let repoA = Repository(
      id: RepositoryID(rootA.path(percentEncoded: false)),
      rootURL: rootA,
      name: "repo-a",
      worktrees: IdentifiedArray(uniqueElements: [mainA, pinnedA])
    )
    let repoB = Repository(
      id: RepositoryID(rootB.path(percentEncoded: false)),
      rootURL: rootB,
      name: "repo-b",
      worktrees: IdentifiedArray(uniqueElements: [mainB, pinnedB])
    )
    var state = makeState(repositories: [repoA, repoB])
    state.$sidebar.withLock { sidebar in
      for (repoID, pinnedID) in [(repoA.id, pinnedA.id), (repoB.id, pinnedB.id)] {
        var section = sidebar.sections[repoID] ?? .init()
        var pinnedBucket = section.buckets[.pinned] ?? .init()
        pinnedBucket.items[pinnedID] = .init()
        section.buckets[.pinned] = pinnedBucket
        sidebar.sections[repoID] = section
      }
    }

    let structure = state.computeSidebarStructure(groupPinned: true, groupActive: false)

    #expect(structure.hoistSummaryByRepositoryID[repoA.id]?.revealTarget == pinnedA.id)
    #expect(structure.hoistSummaryByRepositoryID[repoB.id]?.revealTarget == pinnedB.id)
    #expect(structure.hoistSummaryByRepositoryID[repoA.id]?.pinnedCount == 1)
    #expect(structure.hoistSummaryByRepositoryID[repoB.id]?.pinnedCount == 1)
  }

  @Test func hoistSummaryTalliesMultipleRowsPerBucket() {
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")
    let main = makeMainWorktree(repoRoot: repoRoot)
    let pin1 = makeWorktree(id: "/tmp/repo/pin1", name: "pin1", repoRoot: repoRoot)
    let pin2 = makeWorktree(id: "/tmp/repo/pin2", name: "pin2", repoRoot: repoRoot)
    let busy1 = makeWorktree(id: "/tmp/repo/busy1", name: "busy1", repoRoot: repoRoot)
    let busy2 = makeWorktree(id: "/tmp/repo/busy2", name: "busy2", repoRoot: repoRoot)
    let repository = Repository(
      id: RepositoryID(repoRoot.path(percentEncoded: false)),
      rootURL: repoRoot,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [main, pin1, pin2, busy1, busy2])
    )
    var state = makeState(repositories: [repository])
    state.$sidebar.withLock { sidebar in
      var section = sidebar.sections[repository.id] ?? .init()
      var pinnedBucket = section.buckets[.pinned] ?? .init()
      pinnedBucket.items[pin1.id] = .init()
      pinnedBucket.items[pin2.id] = .init()
      section.buckets[.pinned] = pinnedBucket
      sidebar.sections[repository.id] = section
    }
    state.sidebarItems[id: busy1.id]?.runningScripts.append(.init(id: UUID(), tint: .blue))
    state.sidebarItems[id: busy2.id]?.runningScripts.append(.init(id: UUID(), tint: .blue))

    let structure = state.computeSidebarStructure(groupPinned: true, groupActive: true)

    let summary = structure.hoistSummaryByRepositoryID[repository.id]
    #expect(summary?.pinnedCount == 2)
    #expect(summary?.activeCount == 2)
    #expect(summary?.label == "+2 pinned, +2 active")
  }

  @Test func hoistSummaryLabelOmitsActiveBucketWhenPinnedOnly() {
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")
    let main = makeMainWorktree(repoRoot: repoRoot)
    let pinned = makeWorktree(id: "/tmp/repo/pinned", name: "pinned", repoRoot: repoRoot)
    let repository = Repository(
      id: RepositoryID(repoRoot.path(percentEncoded: false)),
      rootURL: repoRoot,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [main, pinned])
    )
    var state = makeState(repositories: [repository])
    state.$sidebar.withLock { sidebar in
      var section = sidebar.sections[repository.id] ?? .init()
      var pinnedBucket = section.buckets[.pinned] ?? .init()
      pinnedBucket.items[pinned.id] = .init()
      section.buckets[.pinned] = pinnedBucket
      sidebar.sections[repository.id] = section
    }

    let structure = state.computeSidebarStructure(groupPinned: true, groupActive: true)

    let summary = structure.hoistSummaryByRepositoryID[repository.id]
    #expect(summary?.activeCount == 0)
    #expect(summary?.label == "+1 pinned")
  }

  // MARK: - SidebarItemGroup.translateFilteredMove.

  @Test func translateFilteredMoveMapsAcrossHoistedRows() {
    let full: [Worktree.ID] = ["a", "b", "c", "d", "e"]
    let visible: [Worktree.ID] = ["a", "b", "d", "e"]  // c is hoisted.

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
    let full: [Worktree.ID] = ["a", "b", "c", "d"]
    let visible: [Worktree.ID] = ["a", "c", "d"]  // b is hoisted.

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
    let full: [Worktree.ID] = ["a", "b", "c"]
    let visible: [Worktree.ID] = ["a", "c"]

    let result = SidebarItemGroup.translateFilteredMove(
      offsets: IndexSet([5]),
      destination: 0,
      visibleIDs: visible,
      fullIDs: full
    )
    #expect(result == nil)
  }

  @Test func translateFilteredMoveReturnsNilForOutOfRangeDestination() {
    let full: [Worktree.ID] = ["a", "b", "c"]
    let visible: [Worktree.ID] = ["a", "c"]

    let result = SidebarItemGroup.translateFilteredMove(
      offsets: IndexSet([0]),
      destination: 99,
      visibleIDs: visible,
      fullIDs: full
    )
    #expect(result == nil)
  }

  @Test func translateFilteredMoveReturnsNilWhenVisibleHasIDNotInFull() {
    let full: [Worktree.ID] = ["a", "b"]
    let visible: [Worktree.ID] = ["a", "ghost"]  // "ghost" isn't in full.

    let result = SidebarItemGroup.translateFilteredMove(
      offsets: IndexSet([1]),
      destination: 0,
      visibleIDs: visible,
      fullIDs: full
    )
    #expect(result == nil)
  }

  @Test func translateFilteredMoveAppliedYieldsExpectedFullOrder() {
    let full: [Worktree.ID] = ["a", "b", "c", "d", "e"]
    let visible: [Worktree.ID] = ["a", "b", "d", "e"]  // c is hoisted.

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
    let full: [Worktree.ID] = ["a", "b"]
    let visible: [Worktree.ID] = ["a", "b"]

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
    let full: [Worktree.ID] = ["a", "b", "c", "d"]  // d is hoisted.
    let visible: [Worktree.ID] = ["a", "b", "c"]

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

  // MARK: - Selection slice cache.

  /// Poisons the cache so a recompute is observable: if the action's
  /// invalidations don't include `.sidebarSelectionSlice`, the sentinel survives.
  private static let poisonedSelectionSlice = SidebarSelectionSlice(
    rows: [],
    archiveTargets: [],
    deleteTargets: [],
    hasMixedKindSelection: true,
    isAllFoldersBulk: true
  )

  private func makeRepository(path: String) -> Repository {
    let repoRoot = URL(fileURLWithPath: path)
    return Repository(
      id: RepositoryID(repoRoot.path(percentEncoded: false)),
      rootURL: repoRoot,
      name: repoRoot.lastPathComponent,
      worktrees: IdentifiedArray(uniqueElements: [makeMainWorktree(repoRoot: repoRoot)])
    )
  }

  private func makeFolderRepository(path: String) -> Repository {
    let folderURL = URL(fileURLWithPath: path)
    return Repository(
      id: RepositoryID(folderURL.path(percentEncoded: false)),
      rootURL: folderURL,
      name: folderURL.lastPathComponent,
      worktrees: IdentifiedArray(
        uniqueElements: [
          Worktree(
            id: Repository.folderWorktreeID(for: folderURL),
            name: folderURL.lastPathComponent,
            detail: "",
            workingDirectory: folderURL,
            repositoryRootURL: folderURL
          )
        ]
      ),
      isGitRepository: false
    )
  }

  @Test func selectionChangeRecomputesSelectionSlice() {
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")
    let main = makeMainWorktree(repoRoot: repoRoot)
    let feature = makeWorktree(id: "/tmp/repo/wt", name: "feature", repoRoot: repoRoot)
    let repository = Repository(
      id: RepositoryID(repoRoot.path(percentEncoded: false)),
      rootURL: repoRoot,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [main, feature])
    )
    var state = makeState(repositories: [repository])
    state.sidebarSelectionSlice = Self.poisonedSelectionSlice

    state.sidebarSelectedWorktreeIDs = [feature.id]
    let action = RepositoriesFeature.Action.setSidebarSelectedWorktreeIDs([feature.id])
    #expect(action.cacheInvalidations.contains(.sidebarSelectionSlice))
    state.applyCacheRecomputes(action.cacheInvalidations)

    #expect(state.sidebarSelectionSlice.rows.map(\.id) == [feature.id])
    #expect(!state.sidebarSelectionSlice.hasMixedKindSelection)
    #expect(!state.sidebarSelectionSlice.isAllFoldersBulk)
  }

  @Test func perLeafTicksLeaveSelectionSliceUntouched() {
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")
    let main = makeMainWorktree(repoRoot: repoRoot)
    let feature = makeWorktree(id: "/tmp/repo/wt", name: "feature", repoRoot: repoRoot)
    let repository = Repository(
      id: RepositoryID(repoRoot.path(percentEncoded: false)),
      rootURL: repoRoot,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [main, feature])
    )
    var state = makeState(repositories: [repository])
    state.sidebarSelectedWorktreeIDs = [feature.id]

    // An agent tick, a notification append, and a running-script update are the
    // per-leaf storms the sidebar rule forbids fanning out to every row.
    let ticks: [RepositoriesFeature.Action] = [
      .sidebarItems(.element(id: feature.id, action: .agentSnapshotChanged(.init(isWorking: true)))),
      .sidebarItems(
        .element(
          id: feature.id,
          action: .terminalProjectionChanged(
            WorktreeRowProjection(
              surfaceIDs: [],
              isProgressBusy: true,
              hasUnseenNotifications: true,
              notifications: [],
              runningScripts: [.init(id: UUID(), tint: .blue)]
            )
          )
        )
      ),
    ]

    for tick in ticks {
      state.sidebarSelectionSlice = Self.poisonedSelectionSlice
      #expect(!tick.cacheInvalidations.contains(.sidebarSelectionSlice))
      state.applyCacheRecomputes(tick.cacheInvalidations)
      #expect(state.sidebarSelectionSlice == Self.poisonedSelectionSlice)
    }
  }

  @Test func contextMenuOpenWorktreeLeavesSelectionSliceUntouched() {
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")
    let main = makeMainWorktree(repoRoot: repoRoot)
    let repository = Repository(
      id: RepositoryID(repoRoot.path(percentEncoded: false)),
      rootURL: repoRoot,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [main])
    )
    var state = makeState(repositories: [repository])
    state.sidebarSelectionSlice = Self.poisonedSelectionSlice

    let action = RepositoriesFeature.Action.contextMenuOpenWorktree(main.id, .finder)
    #expect(action.cacheInvalidations.isEmpty)
    state.applyCacheRecomputes(action.cacheInvalidations)

    #expect(state.sidebarSelectionSlice == Self.poisonedSelectionSlice)
  }

  @Test func pinFlipRecomputesSelectionSliceSoTheContextMenuLabelStaysFresh() {
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")
    let main = makeMainWorktree(repoRoot: repoRoot)
    let feature = makeWorktree(id: "/tmp/repo/wt", name: "feature", repoRoot: repoRoot)
    let repository = Repository(
      id: RepositoryID(repoRoot.path(percentEncoded: false)),
      rootURL: repoRoot,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [main, feature])
    )
    var state = makeState(repositories: [repository])
    state.sidebarSelectedWorktreeIDs = [feature.id]
    state.applyCacheRecomputes(.all)
    #expect(state.sidebarSelectionSlice.rows.first?.isPinned == false)

    state.sidebarItems[id: feature.id]?.isPinned = true
    let action = RepositoriesFeature.Action.pinWorktree(feature.id)
    #expect(action.cacheInvalidations.contains(.sidebarSelectionSlice))
    state.applyCacheRecomputes(action.cacheInvalidations)

    #expect(state.sidebarSelectionSlice.rows.first?.isPinned == true)
  }

  @Test func setMoveNotifiedWorktreeToTopArmsSidebarStructureRecompute() {
    // The setting drives the highlight sort, so toggling it at runtime must
    // recompute the cached structure. Guards the mapping from reverting to [].
    let action = RepositoriesFeature.Action.setMoveNotifiedWorktreeToTop(true)
    #expect(action.cacheInvalidations.contains(.sidebarStructure))
  }

  @Test func mixedKindSelectionIsFlaggedAndAllFolderSelectionIsBulk() {
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")
    let main = makeMainWorktree(repoRoot: repoRoot)
    let repository = Repository(
      id: RepositoryID(repoRoot.path(percentEncoded: false)),
      rootURL: repoRoot,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [main])
    )
    let folderA = makeFolderRepository(path: "/tmp/folderA")
    let folderB = makeFolderRepository(path: "/tmp/folderB")
    let folderAID = Repository.folderWorktreeID(for: folderA.rootURL)
    let folderBID = Repository.folderWorktreeID(for: folderB.rootURL)
    var state = makeState(repositories: [repository, folderA, folderB])

    state.sidebarSelectedWorktreeIDs = [main.id, folderAID]
    state.applyCacheRecomputes(.sidebarSelectionSlice)
    #expect(state.sidebarSelectionSlice.rows.count == 2)
    #expect(state.sidebarSelectionSlice.hasMixedKindSelection)
    #expect(!state.sidebarSelectionSlice.isAllFoldersBulk)

    state.sidebarSelectedWorktreeIDs = [folderAID, folderBID]
    state.applyCacheRecomputes(.sidebarSelectionSlice)
    #expect(state.sidebarSelectionSlice.rows.count == 2)
    #expect(!state.sidebarSelectionSlice.hasMixedKindSelection)
    #expect(state.sidebarSelectionSlice.isAllFoldersBulk)
  }

  // MARK: - Open-action resolution.

  /// Poisons the map so any write by the post-reduce hook is observable: the hook
  /// is pure, so the sentinel must survive every action.
  private static let poisonedOpenActionMap: [Repository.ID: OpenWorktreeAction] = [
    RepositoryID("/tmp/poison"): .xcode
  ]

  private struct OpenActionStorage {
    let settings = SettingsTestStorage()
    let local = RepositoryLocalSettingsTestStorage()
    let settingsFileURL = URL(fileURLWithPath: "/tmp/supacode-settings-\(UUID().uuidString).json")

    func apply(to values: inout DependencyValues) {
      values.settingsFileStorage = settings.storage
      values.settingsFileURL = settingsFileURL
      values.repositoryLocalSettingsStorage = local.storage
    }

    func seedSettingsFile(_ mutate: (inout SettingsFile) -> Void) {
      withDependencies {
        apply(to: &$0)
      } operation: {
        @Shared(.settingsFile) var settingsFile
        $settingsFile.withLock { mutate(&$0) }
      }
    }

    func seedLocalSettings(_ settings: RepositorySettings, repoRoot: URL) throws {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try local.save(
        encoder.encode(settings),
        at: SupacodePaths.repositorySettingsURL(for: repoRoot)
      )
    }
  }

  /// Precedence, in one pass off the reducer: the local `supacode.json` wins,
  /// then the global settings-file entry, then the global default editor, then
  /// the preferred installed default. A remote repo has no local file to read.
  @Test(.dependencies) func resolutionAppliesLocalThenGlobalThenDefaultPrecedence() async throws {
    let storage = OpenActionStorage()
    let localRoot = URL(fileURLWithPath: "/tmp/resolve-local")
    let globalRoot = URL(fileURLWithPath: "/tmp/resolve-global")
    let plainRoot = URL(fileURLWithPath: "/tmp/resolve-plain")
    let local = makeRepository(path: localRoot.path(percentEncoded: false))
    let global = makeRepository(path: globalRoot.path(percentEncoded: false))
    let plain = makeRepository(path: plainRoot.path(percentEncoded: false))

    var localSettings = RepositorySettings.default
    localSettings.openActionID = OpenWorktreeAction.zed.settingsID
    try storage.seedLocalSettings(localSettings, repoRoot: localRoot)

    var globalSettings = RepositorySettings.default
    globalSettings.openActionID = OpenWorktreeAction.finder.settingsID
    storage.seedSettingsFile {
      $0.global.defaultEditorID = OpenWorktreeAction.terminal.settingsID
      $0.repositories[globalRoot.path(percentEncoded: false)] = globalSettings
    }

    var state = makeState(repositories: [local, global, plain])
    state.installedOpenActions = [.cursor, .zed, .terminal, .finder]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      storage.apply(to: &$0)
    }

    // The settings-file entry and the default editor are already in memory, so the seed
    // answers for them at once. Only the repository whose `supacode.json` overrides both
    // has to wait for the disk.
    await store.send(.resolveOpenActions) {
      $0.openActionByRepositoryID = [
        local.id: .terminal,
        global.id: .finder,
        plain.id: .terminal,
      ]
    }
    await store.receive(\.openActionsResolved) {
      $0.openActionByRepositoryID[local.id] = .zed
    }
    await store.finish()
  }

  /// A remote repo's `rootURL` points at the remote host's path: reading a local
  /// `supacode.json` there would resolve some unrelated local directory.
  @Test(.dependencies) func resolutionNeverReadsLocalSettingsForRemoteRepositories() async {
    let storage = OpenActionStorage()
    let localRepo = makeRepository(path: "/tmp/resolve-mixed-local")
    let remoteConfig = TestRemoteRepo(host: RemoteHost(alias: "devbox"), remotePath: "/home/me/proj")
    let remoteWorktree = RepositoriesFeature.remoteMainWorktree(config: remoteConfig)
    let remoteRepo = Repository(
      id: RepositoriesFeature.remoteRepositoryID(for: remoteConfig),
      rootURL: URL(fileURLWithPath: remoteConfig.normalizedRemotePath),
      name: remoteConfig.resolvedDisplayName,
      worktrees: IdentifiedArray(uniqueElements: [remoteWorktree]),
      isGitRepository: true,
      host: remoteConfig.host
    )
    storage.seedSettingsFile { $0.global.defaultEditorID = OpenWorktreeAction.terminal.settingsID }

    var state = makeState(repositories: [localRepo, remoteRepo])
    state.installedOpenActions = [.cursor, .terminal, .finder]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      storage.apply(to: &$0)
    }

    // Both seed to the default editor from memory, and the pass confirms it.
    await store.send(.resolveOpenActions) {
      $0.openActionByRepositoryID = [
        localRepo.id: .terminal,
        remoteRepo.id: .terminal,
      ]
    }
    await store.receive(\.openActionsResolved)
    await store.finish()

    // Exactly one probe: the local repo's. The remote repo never touches disk.
    #expect(storage.local.loadCount == 1)
    #expect(storage.local.saveCount == 0)
  }

  /// Nothing watches `supacode.json`, so a pass that skipped repositories already in
  /// the map would never revisit them: an agent or a `git pull` inside a Supacode
  /// terminal rewrites that file with no app activation to catch it. Every pass
  /// re-reads every repository, and an unchanged result writes nothing.
  @Test(.dependencies) func everyPassRereadsEveryRepositoryAndWritesOnlyWhatChanged() async {
    let storage = OpenActionStorage()
    let repoA = makeRepository(path: "/tmp/roster-a")
    let repoB = makeRepository(path: "/tmp/roster-b")
    storage.seedSettingsFile { $0.global.defaultEditorID = OpenWorktreeAction.finder.settingsID }

    var state = makeState(repositories: [repoA, repoB])
    state.installedOpenActions = [.cursor, .terminal, .finder]
    state.openActionByRepositoryID = [repoA.id: .cursor]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      storage.apply(to: &$0)
    }

    // `repoA` is already in the map, and is re-read anyway: its stale entry gives way
    // to what the file actually says.
    await store.send(.resolveOpenActions) {
      // `repoB` had no entry, so the seed answers for it from the default editor.
      $0.openActionByRepositoryID[repoB.id] = .finder
    }
    await store.receive(\.openActionsResolved) {
      $0.openActionByRepositoryID[repoA.id] = .finder
    }
    #expect(storage.local.loadCount == 2)

    // A re-read that changes nothing still lands, but writes nothing: no state
    // mutation here means it never churns the map's observers.
    storage.local.resetCounts()
    await store.send(.resolveOpenActions)
    await store.receive(\.openActionsResolved)
    #expect(storage.local.loadCount == 2)
    await store.finish()
  }

  /// `@Shared` references are cached, and anything holding one strongly pins the value
  /// it loaded (every live `WorktreeTerminalState` holds a reader for its repository).
  /// `subscribe` is a no-op, so nothing re-loads it: resolving through the cache would
  /// keep serving the value from when that terminal opened, and re-reading the file is
  /// the entire point of the pass. It has to reach the file even so.
  @Test(.dependencies) func resolutionRereadsTheFileEvenWhileAReaderHoldsTheCachedValue() async {
    let storage = OpenActionStorage()
    let repoRoot = URL(fileURLWithPath: "/tmp/pinned-repo")
    let repo = makeRepository(path: repoRoot.path(percentEncoded: false))
    storage.seedSettingsFile { $0.global.defaultEditorID = OpenWorktreeAction.finder.settingsID }

    var localSettings = RepositorySettings.default
    localSettings.openActionID = OpenWorktreeAction.cursor.settingsID
    try? storage.seedLocalSettings(localSettings, repoRoot: repoRoot)

    var state = makeState(repositories: [repo])
    state.installedOpenActions = [.cursor, .zed, .finder]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      storage.apply(to: &$0)
    }

    // Stand in for the worktree's terminal: hold the reference for the whole test, so
    // the cache entry stays alive exactly as it does in the app.
    let pinned = withDependencies {
      storage.apply(to: &$0)
    } operation: {
      SharedReader(wrappedValue: RepositorySettings.default, .repositorySettings(repoRoot))
    }
    #expect(pinned.wrappedValue.openActionID == OpenWorktreeAction.cursor.settingsID)

    // An agent rewrites `supacode.json`. The held reader still reports Cursor.
    localSettings.openActionID = OpenWorktreeAction.zed.settingsID
    try? storage.seedLocalSettings(localSettings, repoRoot: repoRoot)
    #expect(pinned.wrappedValue.openActionID == OpenWorktreeAction.cursor.settingsID)

    // The seed cannot see `supacode.json`, so it answers with the default editor and the
    // pass corrects it from the file.
    await store.send(.resolveOpenActions) {
      $0.openActionByRepositoryID = [repo.id: .finder]
    }
    await store.receive(\.openActionsResolved) {
      $0.openActionByRepositoryID[repo.id] = .zed
    }
    await store.finish()
  }

  /// A repository can leave the roster while the pass is in flight: the post-reduce
  /// prune has already run by the time the result lands, and nothing prunes again, so
  /// a resurrected key would sit in the map owned by no repository.
  @Test(.dependencies) func resolutionNeverResurrectsARepositoryThatLeftTheRoster() async {
    let repoA = makeRepository(path: "/tmp/ghost-a")
    let removed = makeRepository(path: "/tmp/ghost-removed")
    var state = makeState(repositories: [repoA])
    state.openActionByRepositoryID = [repoA.id: .zed]
    let store = TestStore(initialState: state) { RepositoriesFeature() }

    await store.send(.openActionsResolved([repoA.id: .cursor, removed.id: .finder])) {
      $0.openActionByRepositoryID[repoA.id] = .cursor
    }
  }

  /// The roster reconcile the post-reduce hook still owns: pruning is pure, so it
  /// stays in the reducer while resolution moved to the effect.
  @Test func postReduceHookPrunesEntriesForDroppedRepositories() {
    let repoA = makeRepository(path: "/tmp/prune-a")
    let repoB = makeRepository(path: "/tmp/prune-b")
    var state = makeState(repositories: [repoA, repoB])
    state.openActionByRepositoryID = [repoA.id: .zed, repoB.id: .finder]

    state.repositories.remove(id: repoB.id)
    state.applyCacheRecomputes(
      RepositoriesFeature.Action.repositoriesLoaded([], failures: [], roots: [], animated: false)
        .cacheInvalidations
    )

    #expect(state.openActionByRepositoryID == [repoA.id: .zed])
  }

  /// The invalidation table is what arms resolution, so lock every arm that can
  /// change one of the map's inputs: the roster, the installed editors, the settings.
  @Test func everyArmThatCanChangeTheMapArmsResolution() {
    let arms: [RepositoriesFeature.Action] = [
      .repositoriesLoaded([], failures: [], roots: [], animated: false),
      .openRepositoriesFinished([], failures: [], invalidRoots: [], roots: []),
      .repositoryRemovalCompleted("/tmp/repo", outcome: .success, selectionWasRemoved: false),
      .repositoriesRemoved(["/tmp/repo"], selectionWasRemoved: false),
      .removeFailedRepository("/tmp/repo"),
      .remoteRepositoryResolved(
        repositoryID: "/tmp/repo",
        repository: makeRepository(path: "/tmp/repo"),
        failureMessage: nil
      ),
      .setInstalledOpenActions([.cursor, .finder]),
      .openActionSettingsChanged,
    ]
    for action in arms {
      #expect(action.cacheInvalidations.contains(.openActionResolution))
    }
  }

  @Test func perLeafTicksAndContextMenuOpenNeverArmOpenActionResolution() {
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")
    let main = makeMainWorktree(repoRoot: repoRoot)
    let feature = makeWorktree(id: "/tmp/repo/wt", name: "feature", repoRoot: repoRoot)
    let repository = Repository(
      id: RepositoryID(repoRoot.path(percentEncoded: false)),
      rootURL: repoRoot,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [main, feature])
    )
    var state = makeState(repositories: [repository])

    let actions: [RepositoriesFeature.Action] = [
      .sidebarItems(.element(id: feature.id, action: .agentSnapshotChanged(.init(isWorking: true)))),
      .sidebarItems(.element(id: feature.id, action: .diffStatsChanged(added: 3, removed: 1))),
      .sidebarItems(.element(id: feature.id, action: .dragSessionChanged(isDragging: true))),
      .contextMenuOpenWorktree(feature.id, .finder),
      .pinWorktree(feature.id),
    ]

    for action in actions {
      state.openActionByRepositoryID = Self.poisonedOpenActionMap
      #expect(!action.cacheInvalidations.contains(.openActionResolution))
      state.applyCacheRecomputes(action.cacheInvalidations)
      #expect(state.openActionByRepositoryID == Self.poisonedOpenActionMap)
    }
  }

  /// The regression lock: the post-reduce hook is pure. Resolving an open action
  /// reads a `supacode.json` per repository, and doing that from the reducer is
  /// what hung the app on right-click (#657).
  @Test(.dependencies) func postReduceHookPerformsNoSettingsIO() {
    let storage = OpenActionStorage()
    let repoA = makeRepository(path: "/tmp/pure-a")
    let repoB = makeRepository(path: "/tmp/pure-b")
    storage.seedSettingsFile { $0.global.defaultEditorID = OpenWorktreeAction.finder.settingsID }

    withDependencies {
      storage.apply(to: &$0)
    } operation: {
      var state = makeState(repositories: [repoA, repoB])
      state.installedOpenActions = [.cursor, .finder]
      storage.local.resetCounts()
      storage.settings.resetCounts()

      // Every bit, including the ones a roster change and a settings change declare.
      let invalidations: [CacheInvalidations] = [
        .all,
        .allSidebar,
        .openActionResolution,
        RepositoriesFeature.Action.repositoriesLoaded([], failures: [], roots: [], animated: false)
          .cacheInvalidations,
        RepositoriesFeature.Action.setInstalledOpenActions([.cursor]).cacheInvalidations,
        RepositoriesFeature.Action.openActionSettingsChanged.cacheInvalidations,
      ]
      for invalidation in invalidations {
        state.applyCacheRecomputes(invalidation)
      }

      #expect(storage.local.loadCount == 0)
      #expect(storage.local.saveCount == 0)
      #expect(storage.settings.loadCount == 0)
      #expect(storage.settings.saveCount == 0)
      // The map is untouched by the hook; only `.openActionsResolved` writes it.
      #expect(state.openActionByRepositoryID.isEmpty)
    }
  }

  // MARK: - Alert confirmations.

  @Test func deleteConfirmationsInvalidateEveryRowDerivedCache() {
    // Both confirm handlers seed `removingRepositoryIDs` and call `syncSidebar`,
    // which flips a pending row's lifecycle to `.deleting`.
    let targets = [
      RepositoriesFeature.DeleteWorktreeTarget(worktreeID: "/tmp/repo/wt", repositoryID: "/tmp/repo")
    ]
    let confirmItems = RepositoriesFeature.Action.alert(
      .presented(.confirmDeleteSidebarItems(targets, disposition: .gitWorktreeDelete))
    )
    let confirmRepository = RepositoriesFeature.Action.alert(
      .presented(.confirmDeleteRepository("/tmp/repo"))
    )
    #expect(confirmItems.cacheInvalidations == .allSidebar)
    #expect(confirmRepository.cacheInvalidations == .allSidebar)

    // The remaining alert arms only clear the alert and forward.
    let dismiss = RepositoriesFeature.Action.alert(.dismiss)
    let archive = RepositoriesFeature.Action.alert(
      .presented(.confirmArchiveWorktree("/tmp/repo/wt", "/tmp/repo"))
    )
    #expect(dismiss.cacheInvalidations.isEmpty)
    #expect(archive.cacheInvalidations.isEmpty)
  }

  @Test func reconcileMirrorsAttachedAndWorkingDirectoryPathOntoTheLeaf() {
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")
    let main = makeMainWorktree(repoRoot: repoRoot)
    let detached = Worktree(
      id: WorktreeID("/tmp/repo/wt"),
      name: "wt",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt"),
      repositoryRootURL: repoRoot,
      isAttached: false
    )
    let host = RemoteHost(alias: "devbox")
    let remote = Worktree(
      location: .remote(host, workingDirectory: "/home/me/proj", repositoryRoot: "/home/me/proj"),
      kind: .git,
      name: "main",
      detail: ""
    )
    let repository = Repository(
      id: RepositoryID(repoRoot.path(percentEncoded: false)),
      rootURL: repoRoot,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [main, detached])
    )
    let remoteRepository = Repository(
      location: .remote(host, path: "/home/me/proj"),
      kind: .git,
      name: "proj",
      worktrees: IdentifiedArray(uniqueElements: [remote])
    )
    let state = makeState(repositories: [repository, remoteRepository])

    #expect(state.sidebarItems[id: detached.id]?.isAttached == false)
    #expect(state.sidebarItems[id: detached.id]?.workingDirectoryPath == "/tmp/repo/wt")
    #expect(state.sidebarItems[id: main.id]?.isAttached == true)
    // The remote row keeps the remote path verbatim: the context menu hands it to
    // the editor's Remote-SSH argv, so it must not round-trip through a URL.
    #expect(state.sidebarItems[id: remote.id]?.workingDirectoryPath == "/home/me/proj")
    #expect(state.sidebarItems[id: remote.id]?.host == host)

    // The context row is the menu's only input, so it must carry them through.
    guard let leaf = state.sidebarItems[id: remote.id] else {
      Issue.record("Missing leaf for the remote row.")
      return
    }
    let contextRow = SidebarContextRow(leaf)
    #expect(contextRow.workingDirectoryPath == "/home/me/proj")
    #expect(contextRow.host == host)
    #expect(contextRow.isAttached)
  }

  @Test func archiveTargetsExcludeMainWorktreeAndNonIdleRows() {
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")
    let main = makeMainWorktree(repoRoot: repoRoot)
    let idle = makeWorktree(id: "/tmp/repo/idle", name: "idle", repoRoot: repoRoot)
    let busy = makeWorktree(id: "/tmp/repo/busy", name: "busy", repoRoot: repoRoot)
    let repository = Repository(
      id: RepositoryID(repoRoot.path(percentEncoded: false)),
      rootURL: repoRoot,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [main, idle, busy])
    )
    var state = makeState(repositories: [repository])
    state.sidebarItems[id: busy.id]?.lifecycle = .archiving
    state.sidebarSelectedWorktreeIDs = [main.id, idle.id, busy.id]

    state.applyCacheRecomputes(.sidebarSelectionSlice)

    // Archive spares the main worktree; delete spares only the non-idle row.
    #expect(state.sidebarSelectionSlice.archiveTargets.map(\.worktreeID) == [idle.id])
    #expect(state.sidebarSelectionSlice.deleteTargets.map(\.worktreeID) == [main.id, idle.id])
  }
}
