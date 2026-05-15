import ComposableArchitecture
import CustomDump
import Foundation
import OrderedCollections
import Testing

@testable import supacode

/// Asserts every `sidebarItems` id appears exactly once in `sidebarGrouping` (and vice versa),
/// that `surfaceToItemID` round-trips both directions against each row's `surfaceIDs`,
/// and that every grouped id resolves to a row owned by the bucket's repository.
/// Failures print a `customDump` diff.
///
/// **Invariant relaxed for archived rows**: archived worktrees stay in `sidebarItems`
/// (so per-row PR / diff data survives across archive transitions) but are intentionally
/// absent from `sidebarGrouping` unless their delete-script is running. Rows that fall
/// into that bucket are NOT reported as orphans.
///
/// **Invariant relaxed for in-flight rows**: rows whose worktree dropped out of the
/// roster mid-archive / mid-delete are carried forward by `reconcileSidebarItems`
/// until lifecycle returns to `.idle`. They're not in `sidebarGrouping` either.
@MainActor
func XCTAssertSidebarConsistent(
  _ state: RepositoriesFeature.State,
  fileID: StaticString = #fileID,
  filePath: StaticString = #filePath,
  line: UInt = #line,
  column: UInt = #column
) {
  let itemIDs = Set(state.sidebarItems.ids)
  var groupedIDs: Set<SidebarItemID> = []
  var duplicates: [SidebarItemID] = []
  var crossRepoLeaks: [String] = []
  for (repositoryID, grouping) in state.sidebarGrouping.bucketsByRepository {
    for id in grouping.items.values.flatMap({ $0 }) {
      if !groupedIDs.insert(id).inserted {
        duplicates.append(id)
      }
      if let row = state.sidebarItems[id: id], row.repositoryID != repositoryID {
        crossRepoLeaks.append("\(id) grouped under \(repositoryID) but row owns \(row.repositoryID)")
      }
    }
  }

  // Filter out rows that are intentionally retained outside the grouping:
  // archived rows (per-row PR/diff preservation) and in-flight rows
  // (carry-forward across roster drops).
  let archivedIDs = state.archivedWorktreeIDSet
  let allowedOrphans: Set<SidebarItemID> = Set(
    state.sidebarItems
      .filter { row in
        archivedIDs.contains(row.id) || row.lifecycle != .idle
      }
      .map(\.id)
  )
  let orphanedItems = itemIDs.subtracting(groupedIDs).subtracting(allowedOrphans)
  let orphanedGrouping = groupedIDs.subtracting(itemIDs)

  var unknownSurfaceTargets: [SidebarItemID] = []
  var surfaceForwardMismatches: [String] = []
  for (surfaceID, itemID) in state.surfaceToItemID {
    guard let row = state.sidebarItems[id: itemID] else {
      unknownSurfaceTargets.append(itemID)
      continue
    }
    if !row.surfaceIDs.contains(surfaceID) {
      surfaceForwardMismatches.append("\(surfaceID) → \(itemID) not in row.surfaceIDs")
    }
  }
  var surfaceReverseMismatches: [String] = []
  for row in state.sidebarItems {
    for surfaceID in row.surfaceIDs where state.surfaceToItemID[surfaceID] != row.id {
      let mappedTo = state.surfaceToItemID[surfaceID].map(String.init(describing:)) ?? "nil"
      surfaceReverseMismatches.append("row \(row.id) owns \(surfaceID) but index maps to \(mappedTo)")
    }
  }

  let bucketOrderMismatches = sidebarBucketOrderMismatches(state)

  let allFine =
    orphanedItems.isEmpty && orphanedGrouping.isEmpty && duplicates.isEmpty
    && crossRepoLeaks.isEmpty && unknownSurfaceTargets.isEmpty
    && surfaceForwardMismatches.isEmpty && surfaceReverseMismatches.isEmpty
    && bucketOrderMismatches.isEmpty
  guard !allFine else { return }

  let drift = SidebarConsistencyDrift(
    orphanedItemsMissingFromGrouping: Array(orphanedItems).sorted(),
    groupedIDsMissingFromItems: Array(orphanedGrouping).sorted(),
    duplicateGroupingEntries: duplicates.sorted(),
    crossRepositoryLeaks: crossRepoLeaks.sorted(),
    surfaceTargetsMissingFromItems: unknownSurfaceTargets.sorted(),
    surfaceForwardMismatches: surfaceForwardMismatches.sorted(),
    surfaceReverseMismatches: surfaceReverseMismatches.sorted(),
    bucketOrderMismatches: bucketOrderMismatches
  )
  var rendered = ""
  customDump(drift, to: &rendered)
  Issue.record(
    "Sidebar consistency drift:\n\(rendered)",
    sourceLocation: SourceLocation(
      fileID: String(describing: fileID),
      filePath: String(describing: filePath),
      line: Int(line),
      column: Int(column)
    )
  )
}

private struct SidebarConsistencyDrift: Equatable, CustomDumpReflectable {
  var orphanedItemsMissingFromGrouping: [SidebarItemID]
  var groupedIDsMissingFromItems: [SidebarItemID]
  var duplicateGroupingEntries: [SidebarItemID]
  var crossRepositoryLeaks: [String]
  var surfaceTargetsMissingFromItems: [SidebarItemID]
  var surfaceForwardMismatches: [String]
  var surfaceReverseMismatches: [String]
  var bucketOrderMismatches: [String]

  var customDumpMirror: Mirror {
    Mirror(
      self,
      children: [
        "orphanedItemsMissingFromGrouping": orphanedItemsMissingFromGrouping,
        "groupedIDsMissingFromItems": groupedIDsMissingFromItems,
        "duplicateGroupingEntries": duplicateGroupingEntries,
        "crossRepositoryLeaks": crossRepositoryLeaks,
        "surfaceTargetsMissingFromItems": surfaceTargetsMissingFromItems,
        "surfaceForwardMismatches": surfaceForwardMismatches,
        "surfaceReverseMismatches": surfaceReverseMismatches,
        "bucketOrderMismatches": bucketOrderMismatches,
      ],
      displayStyle: .struct
    )
  }
}

/// Compares `state.sidebarGrouping` per-repo bucket orders against the canonical
/// `state.$sidebar.withLock` snapshot, accounting for the projection adjustments
/// `rebuildSidebarGrouping` applies: the repo's main worktree leads `.pinned`
/// (when not archived), and pending worktrees tail `.unpinned`.
@MainActor
private func sidebarBucketOrderMismatches(_ state: RepositoriesFeature.State) -> [String] {
  var mismatches: [String] = []
  let archivedIDs = state.archivedWorktreeIDSet
  for (repositoryID, grouping) in state.sidebarGrouping.bucketsByRepository {
    guard let repository = state.repositories[id: repositoryID] else { continue }

    var expectedPinned: [SidebarItemID] = []
    if let mainWorktree = repository.worktrees.first(where: { state.isMainWorktree($0) }),
      !archivedIDs.contains(mainWorktree.id)
    {
      expectedPinned.append(mainWorktree.id)
    }
    expectedPinned.append(contentsOf: state.orderedPinnedWorktreeIDs(in: repository))
    if grouping.items[.pinned] != expectedPinned {
      mismatches.append(
        "[\(repositoryID)/.pinned] expected \(expectedPinned) got \(grouping.items[.pinned] ?? [])"
      )
    }

    var expectedUnpinned = state.orderedUnpinnedWorktreeIDs(in: repository)
    for pending in state.pendingWorktrees where pending.repositoryID == repositoryID {
      expectedUnpinned.append(pending.id)
    }
    if grouping.items[.unpinned] != expectedUnpinned {
      mismatches.append(
        "[\(repositoryID)/.unpinned] expected \(expectedUnpinned) got \(grouping.items[.unpinned] ?? [])"
      )
    }

    let expectedArchived = repository.worktrees
      .filter { worktree in
        archivedIDs.contains(worktree.id)
          && state.sidebarItems[id: worktree.id]?.lifecycle == .deletingScript
      }
      .map(\.id)
    if grouping.items[.archived] != expectedArchived {
      mismatches.append(
        "[\(repositoryID)/.archived] expected \(expectedArchived) got \(grouping.items[.archived] ?? [])"
      )
    }
  }
  return mismatches.sorted()
}
