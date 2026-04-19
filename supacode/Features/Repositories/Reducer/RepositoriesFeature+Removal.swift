import ComposableArchitecture
import Foundation
import IdentifiedCollections
import SupacodeSettingsShared

/// Extracted removal pipeline — the types that model the
/// request/confirm/drain/terminal flow for folder + git-section
/// removals, plus the helper functions the reducer body calls on
/// that flow. Pure move from `RepositoriesFeature.swift`; the
/// reducer body (which must live in one place because Swift
/// reducers don't support split bodies) still drives this from the
/// main file.
///
/// Keeps `RepositoriesFeature.swift` below the scroll-threshold
/// where "find the handler for action X" becomes a file-wide search.

extension RepositoriesFeature {
  /// What actually happens on disk when a delete request resolves.
  /// One closed sum for the four real outcomes — this replaces the
  /// former 2×2 split between the user-facing `DeleteAction` choice
  /// and the recorded `RemovalIntent`, which could encode
  /// impossible combinations like `(git worktree, .unlink)` and
  /// gave `.delete` two different meanings depending on target
  /// kind.
  ///
  /// `.gitWorktreeDelete` removes the worktree directory (and
  /// optionally its branch) and is per-worktree; the other three
  /// are repo-level and drop the whole section from Supacode, with
  /// `.folderTrash` additionally moving the folder to the Trash.
  enum DeleteDisposition: Equatable, Sendable {
    case gitWorktreeDelete
    case gitRepositoryUnlink
    case folderUnlink
    case folderTrash

    /// Whether the disposition targets a folder repository. Used
    /// by the delete-script pipeline to decide whether a
    /// completion should drain the repo-level batch aggregator.
    var isFolder: Bool {
      switch self {
      case .gitWorktreeDelete, .gitRepositoryUnlink: false
      case .folderUnlink, .folderTrash: true
      }
    }

    /// Whether the disposition removes an entire repo from state
    /// (true for every case except the per-worktree git delete).
    /// Only repo-level dispositions are ever stored in
    /// `removingRepositoryIDs`.
    var isRepositoryLevel: Bool {
      switch self {
      case .gitWorktreeDelete: false
      case .gitRepositoryUnlink, .folderUnlink, .folderTrash: true
      }
    }
  }

  /// Opaque identifier for a batch of repo-level removals. Minted
  /// by the confirm handler so each concurrent flow owns its own
  /// aggregator and they can't clobber one another.
  typealias BatchID = UUID

  /// Per-repo bookkeeping for an in-flight repo-level removal.
  /// Couples the user-confirmed disposition with the owning batch
  /// id so the aggregator can drain the right batch when each
  /// target's `.repositoryRemovalCompleted` lands.
  struct RepositoryRemovalRecord: Equatable, Sendable {
    let disposition: DeleteDisposition
    let batchID: BatchID
  }

  /// Accumulates per-target completion signals for a bulk
  /// repo-level deletion so the reducer can fire a single terminal
  /// `.repositoriesRemoved([ids], ...)` after the whole batch
  /// drains. `pending` starts populated with every target the
  /// confirm handler accepted; each `.repositoryRemovalCompleted`
  /// removes its ID and (on `.success`) appends to `succeeded`.
  /// `selectionWasRemoved` is OR'ed across targets so the sidebar
  /// selection resets exactly once at the terminal.
  struct ActiveRemovalBatch: Equatable, Sendable {
    let id: BatchID
    var pending: Set<Repository.ID>
    var succeeded: [Repository.ID] = []
    var selectionWasRemoved: Bool = false
    /// Per-target failure messages collected as completions drain.
    /// Surfaced in a single consolidated alert when the batch
    /// finishes so bulk trash failures don't clobber each other
    /// via per-target `.presentAlert` races.
    var failureMessagesByRepositoryID: [Repository.ID: String] = [:]
  }

  /// What a per-target `.repositoryRemovalCompleted` signal reports
  /// back to the batch aggregator. Replaces the former
  /// `(succeeded: Bool, failureMessage: String?)` pair so the type
  /// system can no longer express the illegal "succeeded=true AND
  /// failureMessage != nil" combination, and so future failure
  /// reasons can carry structured payloads without another action
  /// parameter.
  enum RemovalOutcome: Equatable, Sendable {
    /// Target completed cleanly. Aggregator appends to
    /// `batch.succeeded` and the terminal `.repositoriesRemoved`
    /// prunes it from state.
    case success
    /// Target failed. `message` is non-nil only when the failure
    /// carries a user-facing explanation the aggregator should
    /// include in the consolidated alert (e.g. `FileManager.trashItem`
    /// errors). Script failures / cancellations / kind-flips pass
    /// `nil` because their alert is already set directly by the
    /// script-completion handler.
    case failure(message: String?)

    /// Shorthand for the success/failure discrimination — keeps
    /// aggregator logic terse when the payload isn't needed.
    var succeeded: Bool {
      switch self {
      case .success: true
      case .failure: false
      }
    }

    /// User-facing failure message, if this outcome carries one.
    var failureMessage: String? {
      switch self {
      case .success: nil
      case .failure(let message): message
      }
    }
  }

  /// Git-only sidebar actions that can be dispatched against a
  /// folder row (hotkey, deeplink). Drives
  /// `folderIncompatibleAlert` so every entry point presents the
  /// same precise copy ("Archive only applies to git repositories.")
  /// instead of a generic "Action not available." Shared across
  /// this feature's hotkey handlers AND the `AppFeature` deeplink
  /// layer so the copy can't drift between entry points.
  enum FolderIncompatibleAction: Equatable, Sendable {
    case archive
    case unarchive
    case pin
    case unpin

    var displayName: String {
      switch self {
      case .archive: "Archive"
      case .unarchive: "Unarchive"
      case .pin: "Pin"
      case .unpin: "Unpin"
      }
    }
  }
}

#if DEBUG
  extension RepositoriesFeature.State {
    /// Seed an active removal batch for tests that drop straight
    /// into `.deleteSidebarItemConfirmed` / `.deleteScriptCompleted`
    /// without going through the confirm handler that normally
    /// mints the id and records dispositions. Callers pass the
    /// disposition each pending repo was confirmed with so the
    /// per-repo record stays coherent. Returns the batch id so
    /// tests can assert its lifecycle.
    ///
    /// `#if DEBUG`-gated because production callers have no reason
    /// to seed the removal state machine externally — the
    /// `.requestDeleteSidebarItems` → `.confirmDeleteSidebarItems`
    /// flow owns that setup — and a misuse from production code
    /// would silently corrupt the batch aggregator.
    @discardableResult
    mutating func seedRemovalBatch(
      pending: [Repository.ID: RepositoriesFeature.DeleteDisposition],
      id: RepositoriesFeature.BatchID = UUID()
    ) -> RepositoriesFeature.BatchID {
      for (repositoryID, disposition) in pending {
        removingRepositoryIDs[repositoryID] = RepositoriesFeature.RepositoryRemovalRecord(
          disposition: disposition, batchID: id
        )
      }
      activeRemovalBatches[id] = RepositoriesFeature.ActiveRemovalBatch(
        id: id, pending: Set(pending.keys)
      )
      return id
    }
  }
#endif

extension RepositoriesFeature {
  /// Shared failure tail for `.deleteScriptCompleted` cancel /
  /// non-zero-exit branches. Folder removals drain the batch so
  /// bulk aggregations don't hang; the aggregator is responsible
  /// for clearing `removingRepositoryIDs` on failure (lookup needs
  /// the record to find the batch). Git worktree deletes have no
  /// repo-level record so this is a no-op for them.
  ///
  /// Resolves the owning repo id from stored state
  /// (`removingRepositoryIDs`) rather than `state.repositories`,
  /// so a concurrent reload / `.removeFailedRepository` race that
  /// pruned the live repo mid-script can't orphan the batch.
  /// Folder worktrees follow the `"folder:" + repoID` convention
  /// (see `Repository.folderWorktreeID(for:)`). Round-trip back to
  /// the repo id via `Repository.repositoryID(fromFolderWorktreeID:)`
  /// so the prefix literal lives in exactly one place.
  func signalFolderRemovalFailure(
    worktreeID: Worktree.ID,
    state: inout State
  ) -> Effect<Action> {
    guard let repositoryID = Repository.repositoryID(fromFolderWorktreeID: worktreeID),
      state.removingRepositoryIDs[repositoryID]?.disposition.isFolder == true
    else { return .none }
    return .send(
      .repositoryRemovalCompleted(
        repositoryID, outcome: .failure(message: nil), selectionWasRemoved: false))
  }

  /// Shared "Action not available" alert shown when a git-only
  /// action (archive / pin / unpin) is dispatched against a
  /// folder repository. Four call sites produced the same
  /// `AlertState` inline before this helper existed — now they
  /// share one construction so the copy can't drift.
  func folderIncompatibleAlert(action: FolderIncompatibleAction) -> AlertState<Alert> {
    messageAlert(
      title: "\(action.displayName) not available",
      message: "\(action.displayName) only applies to git repositories."
    )
  }

  /// Consolidated alert shown when one or more folder trashes
  /// fail within the same batch. Single-target: plain "Delete
  /// from disk failed" with the one error message (same UX as
  /// before). Multi-target: titled with the count, body lists
  /// each failing folder's name + error so users can see which
  /// folders stayed on disk and why.
  ///
  /// `namesByRepositoryID` is resolved by the aggregator at drain
  /// time (BEFORE `.repositoriesRemoved` prunes state) so the
  /// alert shows stable, user-recognizable folder names even if a
  /// concurrent reload removes the repo from `state.repositories`
  /// between the failure signal and the alert construction. Both
  /// fallback paths use the last path component of the repo id so
  /// single-target and multi-target copy stay visually consistent.
  func consolidatedTrashFailureAlert(
    failureMessagesByRepositoryID: [Repository.ID: String],
    namesByRepositoryID: [Repository.ID: String]
  ) -> AlertState<Alert> {
    func displayName(for id: Repository.ID) -> String {
      if let resolved = namesByRepositoryID[id], !resolved.isEmpty {
        return resolved
      }
      let fallback = URL(fileURLWithPath: id).lastPathComponent
      return fallback.isEmpty ? id : fallback
    }
    let count = failureMessagesByRepositoryID.count
    if count == 1, let (id, message) = failureMessagesByRepositoryID.first {
      return messageAlert(
        title: "Delete from disk failed",
        message: "Couldn't move \(displayName(for: id)) to the Trash: \(message)"
      )
    }
    let lines = failureMessagesByRepositoryID
      .map { id, message -> String in "• \(displayName(for: id)): \(message)" }
      .sorted()
      .joined(separator: "\n")
    return messageAlert(
      title: "Delete from disk failed for \(count) folders",
      message: "These folders stayed on disk:\n\n\(lines)"
    )
  }

  func folderRemovalEffect(
    repositoryID: Repository.ID,
    selectionWasRemoved: Bool,
    diskDeletionURL: URL?
  ) -> Effect<Action> {
    // Completion always routes through `.repositoryRemovalCompleted`
    // so the batch aggregator can decide whether to fire the bulk
    // terminal. For the trash path, the effect awaits the trash
    // operation before reporting completion — on failure we pass
    // the localized error message via
    // `RemovalOutcome.failure(message:)` so the aggregator can
    // coalesce parallel failures into a single alert instead of
    // each overwriting `state.alert`.
    guard let diskDeletionURL else {
      return .send(
        .repositoryRemovalCompleted(
          repositoryID, outcome: .success, selectionWasRemoved: selectionWasRemoved))
    }
    return .run { send in
      do {
        try await Task.detached {
          try FileManager.default.trashItem(at: diskDeletionURL, resultingItemURL: nil)
        }.value
        await send(
          .repositoryRemovalCompleted(
            repositoryID, outcome: .success, selectionWasRemoved: selectionWasRemoved))
      } catch {
        repositoriesLogger.warning(
          "Failed to trash folder at \(diskDeletionURL.path(percentEncoded: false)): "
            + error.localizedDescription
        )
        await send(
          .repositoryRemovalCompleted(
            repositoryID,
            outcome: .failure(message: error.localizedDescription),
            selectionWasRemoved: false
          ))
      }
    }
  }

  func confirmationAlertForRepositoryRemoval(
    repositoryID: Repository.ID,
    state: State
  ) -> AlertState<Alert>? {
    guard let repository = state.repositories[id: repositoryID] else {
      return nil
    }
    let isGitRepository = repository.isGitRepository
    return AlertState {
      TextState(isGitRepository ? "Remove repository?" : "Remove folder?")
    } actions: {
      ButtonState(role: .destructive, action: .confirmDeleteRepository(repository.id)) {
        TextState(isGitRepository ? "Remove repository" : "Remove folder")
      }
      ButtonState(role: .cancel) {
        TextState("Cancel")
      }
    } message: {
      TextState(
        isGitRepository
          ? "This removes the repository from Supacode. "
            + "The repository and its worktrees stay on disk."
          : "This removes the folder from Supacode. The folder stays on disk."
      )
    }
  }

  /// Narrow generic message alert used by every dispatched alert
  /// path in this reducer (presentAlert, folder-incompatible,
  /// trash-failure fallback, delete-not-found). Lives here instead
  /// of on the main reducer so helpers in this extension can use
  /// it without exposing more private surface.
  func messageAlert(title: String, message: String) -> AlertState<Alert> {
    AlertState {
      TextState(title)
    } actions: {
      ButtonState(role: .cancel) {
        TextState("OK")
      }
    } message: {
      TextState(message)
    }
  }
}
