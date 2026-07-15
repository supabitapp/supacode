import AppKit
import ComposableArchitecture
import Foundation
import IdentifiedCollections
import OrderedCollections
import PostHog
import SupacodeSettingsShared
import SwiftUI

private enum CancelID {
  static let load = "repositories.load"
  static let persistRoots = "repositories.persistRoots"
  static let toastAutoDismiss = "repositories.toastAutoDismiss"
  static let githubIntegrationAvailability = "repositories.githubIntegrationAvailability"
  static let githubIntegrationRecovery = "repositories.githubIntegrationRecovery"
  static let worktreePromptLoad = "repositories.worktreePromptLoad"
  static let worktreePromptValidation = "repositories.worktreePromptValidation"
  static let resolveRemoteRepositories = "repositories.resolveRemoteRepositories"
  static let resolveOpenActions = "repositories.resolveOpenActions"
  static func delayedPRRefresh(_ worktreeID: Worktree.ID) -> String {
    "repositories.delayedPRRefresh.\(worktreeID)"
  }
}

nonisolated let repositoriesLogger = SupaLogger("Repositories")
private nonisolated let githubIntegrationRecoveryInterval: Duration = .seconds(15)
private nonisolated let toastAutoDismissDelay: Duration = .milliseconds(2500)
private nonisolated let delayedPullRequestRefreshDelay: Duration = .seconds(2)

// Resolve `(host, owner, repo)` for a repository root. `gh repo
// view` honours the user's default-repo resolution (fork →
// upstream), so it wins when available. The git remote parser is
// the fallback for when `gh` is unavailable or unauthenticated.
@Sendable
private func resolveRemoteInfo(
  repositoryRootURL: URL,
  githubCLI: GithubCLIClient,
  gitClient: GitClientDependency
) async -> GithubRemoteInfo? {
  if let info = await githubCLI.resolveRemoteInfo(repositoryRootURL) {
    return info
  }
  return await gitClient.remoteInfo(repositoryRootURL)
}

private nonisolated let worktreeCreationProgressLineLimit = 200
private nonisolated let worktreeCreationProgressUpdateStride = 20

nonisolated struct WorktreeCreationProgressUpdateThrottle {
  private let stride: Int
  private var hasEmittedFirstLine = false
  private var unsentLineCount = 0

  init(stride: Int) {
    precondition(stride > 0)
    self.stride = stride
  }

  mutating func recordLine() -> Bool {
    unsentLineCount += 1
    if !hasEmittedFirstLine {
      hasEmittedFirstLine = true
      unsentLineCount = 0
      return true
    }
    if unsentLineCount >= stride {
      unsentLineCount = 0
      return true
    }
    return false
  }

  mutating func flush() -> Bool {
    guard unsentLineCount > 0 else {
      return false
    }
    unsentLineCount = 0
    return true
  }
}

/// Which status pane the detail inspector shows when presented; presentation is tracked by `inspectorPresented`.
enum WorktreeInspectorPane: Hashable, Sendable {
  case git
  case notifications
}

@Reducer
struct RepositoriesFeature {
  struct PendingSidebarReveal: Equatable {
    let id: Int
    let worktreeID: Worktree.ID
  }

  @ObservableState
  struct State: Equatable {
    var repositories: IdentifiedArrayOf<Repository> = []
    var repositoryRoots: [URL] = []
    var loadFailuresByID: [Repository.ID: String] = [:]
    /// Set when git is environment-blocked (e.g. an unaccepted Xcode license):
    /// drives the banner and suppresses the false per-repo "broken" rows.
    var gitEnvironmentError: GitEnvironmentError?
    /// Remote repositories whose SSH listing is still resolving (shown with a
    /// loading spinner). Cleared per repo as each `.remoteRepositoryResolved`
    /// lands; a repo here with no `loadFailuresByID` entry is "loading", one
    /// with a failure is "can't reach".
    var resolvingRemoteRepositoryIDs: Set<Repository.ID> = []
    var selection: SidebarSelection?
    var isOpenPanelPresented = false
    var isInitialLoadComplete = false
    var pendingWorktrees: [PendingWorktree] = []
    /// In-flight customization payloads, keyed by `(repositoryID, branchName)`
    /// so the New Worktree prompt's `submit` delegate can hand title / color
    /// off without bloating four action signatures in the creation chain.
    /// Drained when the `PendingWorktree` materialises in `createWorktreeInRepository`,
    /// or on a prompt cancel / dismiss.
    var pendingCreationCustomizations: [Repository.ID: [String: PendingWorktree.Customization]] = [:]
    /// CLI worktree-new ack ids parked while a creation prompt is open, keyed by
    /// repository. Consumed when the prompt creates (so the id threads through to
    /// the completion ack) or drained if the prompt is cancelled / dismissed.
    var cliWorktreeAckPendingIDs: [Repository.ID: Worktree.ID] = [:]
    /// In-flight repo-level removals keyed by repository id. Each record
    /// carries the disposition (only `.gitRepositoryUnlink` / `.folderUnlink`
    /// / `.folderTrash`) and the id of the owning batch aggregator that
    /// drains its per-target completion. Presence also drives the sidebar's
    /// "removing" indicator.
    var removingRepositoryIDs: [Repository.ID: RepositoryRemovalRecord] = [:]
    /// Bulk-removal aggregators keyed by batch id, fired as `.repositoriesRemoved`
    /// once `pending` is drained. Dict (not optional) so overlapping batches don't
    /// clobber each other's pending set.
    var activeRemovalBatches: [BatchID: ActiveRemovalBatch] = [:]
    var autoDeleteArchivedWorktreesAfterDays: AutoDeletePeriod?
    var mergedWorktreeAction: MergedWorktreeAction?
    var moveNotifiedWorktreeToTop = false
    /// Installed editors in menu order, mirrored down from `AppFeature` so the
    /// sidebar context menu never probes LaunchServices while building.
    var installedOpenActions: [OpenWorktreeAction] = []
    /// Per-repo resolved open action, stored because resolving it reads
    /// `@Shared(.repositorySettings(...))`, whose reference is cached weakly:
    /// constructed from a view body it would re-run the key's (disk-reading)
    /// load on every menu build. The disk pass (`.openActionsResolved`) is what makes it
    /// authoritative, but `seedUnresolvedOpenActions` fills a new repository's entry from
    /// what is already in memory first, so nothing ever reads an absent one.
    var openActionByRepositoryID: [Repository.ID: OpenWorktreeAction] = [:]
    var shouldRestoreLastFocusedWorktree = false
    var shouldSelectFirstAfterReload = false
    var isRefreshingWorktrees = false
    var statusToast: StatusToast?
    // Inspector presentation is split from the selected pane so a drag-to-collapse
    // (which flips `isPresented` to false transiently) doesn't wipe the pane and
    // leave the column empty when dragged back open.
    var inspectorPresented = false
    var inspectorPane: WorktreeInspectorPane = .git
    var githubIntegrationAvailability: GithubIntegrationAvailability = .unknown
    var pendingPullRequestRefreshByRepositoryID: [Repository.ID: PendingPullRequestRefresh] = [:]
    var inFlightPullRequestRefreshRepositoryIDs: Set<Repository.ID> = []
    /// Branch snapshot per worktree at query-start time; consumed when the result lands
    /// so `pullRequestChanged.branchAtQueryTime` matches the branch the watermark armed.
    var inFlightPullRequestBranchSnapshotsByRepositoryID: [Repository.ID: [Worktree.ID: String]] = [:]
    var queuedPullRequestRefreshByRepositoryID: [Repository.ID: PendingPullRequestRefresh] = [:]
    var sidebarSelectedWorktreeIDs: Set<Worktree.ID> = []
    var nextPendingSidebarRevealID = 0
    var pendingSidebarReveal: PendingSidebarReveal?
    /// Browser-style back/forward stacks for worktree selection.
    /// Fresh selections push the previous worktree onto `back` and
    /// clear `forward`; the dedicated `worktreeHistoryBack` /
    /// `worktreeHistoryForward` actions move the cursor between
    /// stacks without recording. In-memory only — not persisted.
    ///
    /// Recording is gated on both endpoints being concrete worktree
    /// ids — transitions to/from "no selection" or the archive view
    /// are explicitly NOT recorded (see `recordWorktreeHistoryTransition`).
    /// Archive / delete / repository-removal paths additionally
    /// bypass `setSingleWorktreeSelection` entirely (they assign
    /// `state.selection` directly), so their auto-promoted next
    /// selection is also non-recording. Both omissions are
    /// intentional: the back stack should hold worktrees the user
    /// can step back to, not transient empty-selection states or
    /// system-driven cleanup promotions.
    var worktreeHistoryBackStack: [Worktree.ID] = []
    var worktreeHistoryForwardStack: [Worktree.ID] = []
    /// Session-only worktree MRU: most-recent-first, deduped, capped. Every
    /// user-initiated worktree selection (hotkey, palette, and sidebar paths)
    /// hoists the worktree to the head; launch-restore and validation paths
    /// leave it untouched. Drives the ⌘P switcher sort, so ⌘P then Enter is a
    /// Cmd+Tab-style toggle between the two most recent worktrees. Not persisted.
    var worktreeMRU: [Worktree.ID] = []
    /// Single source of truth for all user-curated sidebar state —
    /// section order / collapse / pin / unpin / archive / focused
    /// worktree — persisted to `~/.supacode/sidebar.json`. Replaces
    /// the six legacy slices (pin / archive / repo order / worktree
    /// order / focus / collapsed). All co-mutating actions fold
    /// through `$sidebar.withLock` so the SharedKey emits a single
    /// atomic file update per reducer action.
    @Shared(.sidebar) var sidebar: SidebarState
    /// Mirrors the View menu's "Nest Worktrees by Branch" toggle. Owned by
    /// State so the reducer's hotkey / arrow navigation walks the same
    /// trie-filtered row list the sidebar actually renders.
    @Shared(.sidebarNestWorktreesByBranch) var sidebarNestWorktreesByBranch: Bool
    /// Single source of truth the sidebar view renders against. Recomputed
    /// inside the reducer (see `recomputeSidebarStructureIfChanged()`) so
    /// `SidebarListView.body` is a dumb iterator. The Equatable diff guard
    /// in the recompute helper keeps a no-op rebuild from invalidating
    /// SwiftUI when the user-visible layout didn't actually change.
    var sidebarStructure: SidebarStructure = .placeholder
    /// Cached projection of the focused row's display fields. The detail body
    /// reads this directly instead of `sidebarItems[id: id]` so per-leaf agent
    /// / notification mutations on the focused row don't invalidate the
    /// detail tree. Recomputed via `recomputeSelectedWorktreeSliceIfChanged()`.
    var selectedWorktreeSlice: SelectedWorktreeSlice?
    /// Cached projection of the effective sidebar selection. The sidebar body
    /// and the row context menu read this instead of deriving rows from
    /// `sidebarItems`, which would observation-track every row. Recomputed via
    /// `recomputeSidebarSelectionSliceIfChanged()`.
    var sidebarSelectionSlice: SidebarSelectionSlice = .empty
    /// Cached toolbar notification snapshot. Detail body reads this instead of
    /// iterating `sidebarItems` (which would observe every per-row notification
    /// mutation across all worktrees). Recomputed via
    /// `recomputeToolbarNotificationGroupsIfChanged()`.
    var toolbarNotificationGroupsCache: [ToolbarNotificationRepositoryGroup] = []
    @Presents var worktreeCreationPrompt: WorktreeCreationPromptFeature.State?
    @Presents var repositoryCustomization: RepositoryCustomizationFeature.State?
    @Presents var worktreeCustomization: WorktreeCustomizationFeature.State?
    @Presents var renameBranchPrompt: RenameBranchFeature.State?
    @Presents var remoteConnectionForm: RemoteConnectionFormFeature.State?
    @Presents var cloneRepositoryForm: CloneRepositoryFormFeature.State?
    @Presents var alert: AlertState<Alert>?

    // MARK: - Sidebar items (per-row TCA collection).
    var sidebarItems: IdentifiedArrayOf<SidebarItemFeature.State> = []
    var sidebarGrouping: SidebarGrouping = .empty
    /// Long-lived reader hoisted onto State so `reconcileSidebarItems` stays a
    /// pure static mutator and doesn't re-decode the layouts file on every call.
    @SharedReader(.layouts) var persistedLayouts: [String: TerminalLayoutSnapshot]
    /// Surfaces seeded onto rows from the persisted layout but not yet broadcast
    /// to agent presence. Accumulates across reconciles; the single drain owner
    /// is `AppFeature.repositoriesChanged`, which intersects against live
    /// `agentPresence.bySurface` so stale entries from removed repos no-op.
    var pendingAgentRehydrateSurfaces: Set<UUID> = []
    /// Reverse index from surface UUID to row id, derived from `sidebarItems` so
    /// it cannot drift out of sync.
    var surfaceToItemID: [UUID: SidebarItemID] {
      var index: [UUID: SidebarItemID] = [:]
      for row in sidebarItems {
        for surfaceID in row.surfaceIDs {
          index[surfaceID] = row.id
        }
      }
      return index
    }
  }

  // Removal pipeline types + helpers live in
  // `RepositoriesFeature+Removal.swift` — see that file for
  // `DeleteDisposition`, `RepositoryRemovalRecord`,
  // `ActiveRemovalBatch`, `FolderIncompatibleAction`, `BatchID`,
  // and the `folderRemovalEffect` / `signalFolderRemovalFailure`
  // / `folderIncompatibleAlert` / `consolidatedTrashFailureAlert`
  // / `confirmationAlertForRepositoryRemoval` / `messageAlert`
  // helpers the reducer body below calls into.

  enum GithubIntegrationAvailability: Equatable {
    case unknown
    case checking
    case available
    case unavailable
    case disabled
  }

  struct PendingPullRequestRefresh: Equatable {
    var repositoryRootURL: URL
    var worktreeIDs: [Worktree.ID]
  }

  enum WorktreeCreationNameSource: Equatable {
    case random
    case explicit(String)
  }

  enum WorktreeCreationBaseRefSource: Equatable {
    case repositorySetting
    case explicit(String?)
  }

  enum Action {
    case sidebarItems(IdentifiedActionOf<SidebarItemFeature>)
    case task
    /// Fired by `SidebarListView.onChange` whenever `@Shared(.sidebarGroupPinnedRows)`
    /// or `@Shared(.sidebarGroupActiveRows)` mutates while the sidebar is mounted.
    /// The post-reduce hook picks up the new toggle state and rebuilds the cached
    /// structure; the explicit handler also fires the highlight-onboarding
    /// auto-dismiss. Toggling from the menu while the sidebar column is collapsed
    /// bypasses this action; the matching dismiss in `SidebarCommands` setters
    /// covers that path.
    case sidebarGroupingTogglesChanged
    /// Fired by `SidebarListView.onChange` whenever `@Shared(.sidebarNestWorktreesByBranch)`
    /// mutates. Triggers a structure recompute so the alphabetical per-bucket
    /// sort that nesting forces shows up in `slotByID` / `hotkeySlots` (which
    /// the view reads to assign ⌃1..⌃0 hotkeys).
    case sidebarNestByBranchChanged
    case setOpenPanelPresented(Bool)
    case requestAddRemoteRepository
    case requestEditRemoteRepository(Repository.ID)
    case remoteConnectionForm(PresentationAction<RemoteConnectionFormFeature.Action>)
    case requestCloneRepository
    case cloneRepositoryForm(PresentationAction<CloneRepositoryFormFeature.Action>)
    case removeRemoteRepository(Repository.ID)
    /// Kick off async SSH resolution of every persisted remote config; streams
    /// one `.remoteRepositoryResolved` per repo as each finishes.
    case resolveRemoteRepositories
    case remoteRepositoryResolved(repositoryID: Repository.ID, repository: Repository, failureMessage: String?)
    case loadPersistedRepositories
    case refreshWorktrees
    case reloadRepositories(animated: Bool)
    case repositoriesLoaded([Repository], failures: [LoadFailure], roots: [URL], animated: Bool)
    /// Sole owner of `state.gitEnvironmentError`. Emitted by every load path with
    /// the current git-environment probe result (`nil` clears the banner).
    case gitEnvironmentChanged(GitEnvironmentError?)
    case selectionChanged(Set<SidebarSelection>, focusTerminal: Bool = false)
    case repositoryExpansionChanged(Repository.ID, isExpanded: Bool)
    case branchNestExpansionChanged(
      repositoryID: Repository.ID,
      bucketID: SidebarBucket,
      prefix: String,
      isExpanded: Bool
    )
    /// Expand or collapse every sidebar group at once. Expanding also clears
    /// every nested branch-group prefix so the tree opens fully.
    case setAllSidebarGroupsExpanded(Bool)
    case selectArchivedWorktrees
    case setSidebarSelectedWorktreeIDs(Set<Worktree.ID>)
    case openRepositories([URL])
    case openRepositoriesFinished(
      [Repository],
      failures: [LoadFailure],
      invalidRoots: [String],
      roots: [URL]
    )
    case selectWorktree(Worktree.ID?, focusTerminal: Bool = false)
    case selectWorktreeAtHotkeySlot(Int)
    case selectNextWorktree
    case selectPreviousWorktree
    case worktreeHistoryBack
    case worktreeHistoryForward
    case revealSelectedWorktreeInSidebar
    case revealHoistedWorktreeInSidebar(Worktree.ID)
    case consumePendingSidebarReveal(Int)
    case createRandomWorktree
    case createRandomWorktreeInRepository(Repository.ID, pendingID: Worktree.ID? = nil)
    /// A CLI-initiated creation prompt was abandoned; drains the parked ack.
    case cliWorktreeAckCancelled(pendingID: Worktree.ID)
    case createWorktreeInRepository(
      repositoryID: Repository.ID,
      nameSource: WorktreeCreationNameSource,
      baseRefSource: WorktreeCreationBaseRefSource,
      fetchOrigin: Bool,
      placement: WorktreePlacementOverride? = nil,
      pendingID: Worktree.ID? = nil
    )
    case promptedWorktreeCreationDataLoaded(
      repositoryID: Repository.ID,
      automaticBaseRef: String,
      defaultBranch: String?,
      remoteNames: [String],
      selectedBaseRef: String?
    )
    case promptedWorktreeBranchesLoaded(
      repositoryID: Repository.ID,
      inventory: GitBranchInventory
    )
    case startPromptedWorktreeCreation(
      repositoryID: Repository.ID,
      branchName: String,
      baseRef: String?,
      fetchOrigin: Bool,
      placement: WorktreePlacementOverride
    )
    case promptedWorktreeCreationChecked(
      repositoryID: Repository.ID,
      branchName: String,
      baseRef: String?,
      fetchOrigin: Bool,
      placement: WorktreePlacementOverride,
      duplicateMessage: String?
    )
    case pendingWorktreeProgressUpdated(id: Worktree.ID, progress: WorktreeCreationProgress)
    case createRandomWorktreeSucceeded(
      Worktree,
      repositoryID: Repository.ID,
      pendingID: Worktree.ID
    )
    case createRandomWorktreeFailed(
      title: String,
      message: String,
      pendingID: Worktree.ID,
      previousSelection: Worktree.ID?,
      repositoryID: Repository.ID,
      name: String?,
      baseDirectory: URL
    )
    case consumeSetupScript(Worktree.ID)
    case consumeTerminalFocus(Worktree.ID)
    case scriptCompleted(
      worktreeID: Worktree.ID, kind: BlockingScriptKind, exitCode: Int?, tabId: TerminalTabID?)
    case requestArchiveWorktree(Worktree.ID, Repository.ID)
    case requestArchiveWorktrees([ArchiveWorktreeTarget])
    case archiveWorktreeConfirmed(Worktree.ID, Repository.ID)
    case archiveScriptCompleted(worktreeID: Worktree.ID, exitCode: Int?, tabId: TerminalTabID?)
    case archiveWorktreeApply(Worktree.ID, Repository.ID)
    case unarchiveWorktree(Worktree.ID)
    case requestDeleteSidebarItems([DeleteWorktreeTarget])
    case deleteSidebarItemConfirmed(Worktree.ID, Repository.ID)
    case deleteScriptCompleted(worktreeID: Worktree.ID, exitCode: Int?, tabId: TerminalTabID?)
    case deleteWorktreeApply(Worktree.ID, Repository.ID)
    case worktreeDeleted(
      Worktree.ID,
      repositoryID: Repository.ID,
      selectionWasRemoved: Bool,
      nextSelection: Worktree.ID?
    )
    case repositoriesMoved(IndexSet, Int)
    case pinnedWorktreesMoved(repositoryID: Repository.ID, IndexSet, Int)
    case unpinnedWorktreesMoved(repositoryID: Repository.ID, IndexSet, Int)
    case deleteWorktreeFailed(String, worktreeID: Worktree.ID)
    case requestDeleteRepository(Repository.ID)
    case requestRemoveFailedRepository(Repository.ID)
    case removeFailedRepository(Repository.ID)
    /// Per-target signal feeding the batch aggregator. Every
    /// repo-level removal path (folder via delete pipeline,
    /// git-repo section-level) emits one of these when the target's
    /// per-item work concludes. `.failure` covers script failures
    /// / cancellations / kind-flip / trash failures so a bulk
    /// batch drains even when individual targets fail. `.failure`
    /// with a `message` is collected by the aggregator and
    /// surfaced in a consolidated alert once the batch finishes —
    /// so N parallel trash failures don't each clobber
    /// `state.alert`.
    case repositoryRemovalCompleted(
      Repository.ID,
      outcome: RemovalOutcome,
      selectionWasRemoved: Bool
    )
    /// Bulk terminal: fired exactly once per batch after every
    /// target's `.repositoryRemovalCompleted` has been collected.
    /// Replaces the per-target `.repositoryRemoved` that raced on
    /// `.repositoriesLoaded`. For single-item paths the batch has
    /// size 1 — same code.
    case repositoriesRemoved([Repository.ID], selectionWasRemoved: Bool)
    case pinWorktree(Worktree.ID)
    case unpinWorktree(Worktree.ID)
    case presentAlert(title: String, message: String)
    case worktreeInfoEvent(WorktreeInfoWatcherClient.Event)
    case worktreeBranchNameLoaded(worktreeID: Worktree.ID, name: String)
    case worktreeLineChangesLoaded(worktreeID: Worktree.ID, added: Int, removed: Int)
    case refreshGithubIntegrationAvailability
    case githubIntegrationAvailabilityUpdated(Bool)
    case repositoryPullRequestRefreshCompleted(Repository.ID)
    case repositoryPullRequestsLoaded(
      repositoryID: Repository.ID,
      pullRequestsByWorktreeID: [Worktree.ID: GithubPullRequest?]
    )
    case setGithubIntegrationEnabled(Bool)
    /// Installed editors resolved by `AppFeature`'s LaunchServices sweep. Mirrored
    /// in through an action (not a direct child-state write) so the post-reduce
    /// hook re-arms the open-action resolution.
    case setInstalledOpenActions([OpenWorktreeAction])
    /// A per-repo `openActionID` or the global default editor changed. Carries no
    /// payload: resolution re-reads both from the settings files.
    case openActionSettingsChanged
    /// Rebuild `openActionByRepositoryID` off the main actor. Sent by `AppFeature`
    /// on activation; every arm whose `cacheInvalidations` carry
    /// `.openActionResolution` gets the same effect straight from the post-reduce
    /// hook, without the extra action hop.
    case resolveOpenActions
    /// The resolution effect's result, merged into the map. The only writer of
    /// `openActionByRepositoryID`.
    case openActionsResolved([Repository.ID: OpenWorktreeAction])
    case setMergedWorktreeAction(MergedWorktreeAction?)
    case setAutoDeleteArchivedWorktreesAfterDays(AutoDeletePeriod?)
    case autoDeleteExpiredArchivedWorktrees
    case setMoveNotifiedWorktreeToTop(Bool)
    case pullRequestAction(Worktree.ID, PullRequestAction)
    case showToast(StatusToast)
    case dismissToast
    case toggleInspectorPane(WorktreeInspectorPane)
    case setInspectorPresented(Bool)
    case delayedPullRequestRefresh(Worktree.ID)
    case openRepositorySettings(Repository.ID)
    case requestCustomizeRepository(Repository.ID)
    case requestCustomizeWorktree(Worktree.ID, Repository.ID)
    /// Deeplink / CLI appearance update: overwrites the row's sidebar title and tint.
    /// `nil` clears the field; omit-vs-clear was already resolved upstream in `AppFeature`.
    case setWorktreeAppearance(Worktree.ID, Repository.ID, title: String?, color: RepositoryColor?)
    case requestRenameBranch(Worktree.ID, Repository.ID)
    case contextMenuOpenWorktree(Worktree.ID, OpenWorktreeAction)
    case worktreeCreationPrompt(PresentationAction<WorktreeCreationPromptFeature.Action>)
    case repositoryCustomization(PresentationAction<RepositoryCustomizationFeature.Action>)
    case worktreeCustomization(PresentationAction<WorktreeCustomizationFeature.Action>)
    case renameBranchPrompt(PresentationAction<RenameBranchFeature.Action>)
    case alert(PresentationAction<Alert>)
    case delegate(Delegate)
  }

  struct LoadFailure: Equatable {
    let rootID: Repository.ID
    let message: String
  }

  struct DeleteWorktreeTarget: Hashable {
    let worktreeID: Worktree.ID
    let repositoryID: Repository.ID
  }

  struct ArchiveWorktreeTarget: Hashable {
    let worktreeID: Worktree.ID
    let repositoryID: Repository.ID
  }

  private struct ApplyRepositoriesResult {
    let didPruneArchivedWorktreeIDs: Bool
  }

  enum StatusToast: Equatable {
    case inProgress(String)
    case success(String)
  }

  enum Alert: Hashable {
    case confirmArchiveWorktree(Worktree.ID, Repository.ID)
    case confirmArchiveWorktrees([ArchiveWorktreeTarget])
    case confirmDeleteSidebarItems([DeleteWorktreeTarget], disposition: DeleteDisposition)
    case confirmDeleteRepository(Repository.ID)
    case confirmRemoveFailedRepository(Repository.ID)
    case viewTerminalTab(Worktree.ID, tabId: TerminalTabID)
  }

  enum PullRequestAction: Equatable {
    case openOnGithub
    case markReadyForReview
    case merge
    case close
    case copyFailingJobURL
    case copyCiFailureLogs
    case rerunFailedJobs
    case openFailingCheckDetails
  }

  @CasePathable
  enum Delegate: Equatable {
    case selectedWorktreeChanged(Worktree?)
    case repositoriesChanged(IdentifiedArrayOf<Repository>)
    case openRepositorySettings(Repository.ID)
    case openWorktreeInApp(Worktree.ID, OpenWorktreeAction)
    case worktreeCreated(Worktree)
    case runBlockingScript(Worktree, repositoryID: Repository.ID, kind: BlockingScriptKind, script: String)
    case selectTerminalTab(Worktree.ID, tabId: TerminalTabID)
  }

  @Dependency(AnalyticsClient.self) private var analyticsClient
  @Dependency(GitClientDependency.self) private var gitClient
  @Dependency(GithubCLIClient.self) private var githubCLI
  @Dependency(GithubIntegrationClient.self) private var githubIntegration
  @Dependency(RepositoryPersistenceClient.self) private var repositoryPersistence
  @Dependency(ShellClient.self) private var shellClient
  @Dependency(\.continuousClock) private var clock
  @Dependency(\.date.now) private var now
  @Dependency(\.uuid) private var uuid

  /// Host-aware git client: the SSH flavor for a remote worktree (so branch /
  /// diff lookups run on the host), the injected local client otherwise.
  private func gitClient(for worktree: Worktree) -> GitClientDependency {
    guard let host = worktree.host else {
      return gitClient
    }
    return .ssh(host: host)
  }

  /// Host-aware git client for a repository: the SSH flavor for a remote repo
  /// (so branch availability / inventory lookups run on the host), the injected
  /// local client otherwise.
  private func gitClient(for repository: Repository) -> GitClientDependency {
    guard let host = repository.host else {
      return gitClient
    }
    return .ssh(host: host)
  }

  /// Present the connection form seeded from the existing remote for `repositoryID`.
  /// The id is self-descriptive, so it parses straight back into host + path; a
  /// failed / disconnected remote (which has no loaded `Repository`) is still
  /// editable.
  static func presentRemoteConnectionEditForm(_ repositoryID: Repository.ID, state: inout State) {
    guard let (host, remotePath) = Self.parseRemoteRoot(repositoryID.rawValue) else { return }
    state.remoteConnectionForm = RemoteConnectionFormFeature.State.editing(
      host: host, remotePath: remotePath, repositoryID: repositoryID)
  }

  /// Persist a validated remote connection (add or replace), dropping the
  /// now-orphaned per-repo customization when a host/path edit re-keys the id,
  /// then dismiss the form and reload.
  static func saveRemoteConnection(host: RemoteHost, remotePath: String, state: inout State) -> Effect<Action> {
    let originalRepositoryID: Repository.ID?
    if case .edit(let editedID) = state.remoteConnectionForm?.mode {
      originalRepositoryID = editedID
    } else {
      originalRepositoryID = nil
    }
    let newID = Self.remoteRepositoryID(host: host, remotePath: remotePath)
    @Shared(.remoteRepositoryRoots) var remoteRepositoryRoots
    $remoteRepositoryRoots.withLock { roots in
      // Replace the edited entry in place; for an add, dedupe on the derived id
      // (host authority + port + path) so a second identical connection isn't a
      // duplicate row while a port-distinct one stays separate.
      if let originalRepositoryID, let index = roots.firstIndex(of: originalRepositoryID.rawValue) {
        roots[index] = newID.rawValue
      } else if !roots.contains(newID.rawValue) {
        roots.append(newID.rawValue)
      }
    }
    if let originalRepositoryID, originalRepositoryID != newID {
      state.$sidebar.withLock { $0.sections[originalRepositoryID] = nil }
    }
    state.remoteConnectionForm = nil
    // Full reload so the remote repo materializes even with no local roots.
    return .send(.loadPersistedRepositories)
  }

  /// Removal / delete / unpin + repo-removal handlers, peeled out of `body` so each `Reduce`
  /// closure stays under the Swift type-checker's complexity limit (mirrors
  /// `remoteConnectionFormReducer`). Runs after the main `Reduce`, before the post-reduce hook.
  var worktreeArchiveReducer: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .requestArchiveWorktree(let worktreeID, let repositoryID):
        if state.removingRepositoryIDs[repositoryID] != nil {
          return .none
        }
        guard let repository = state.repositories[id: repositoryID],
          let worktree = repository.worktrees[id: worktreeID]
        else {
          return .none
        }
        // Folder repos have a synthesized main-worktree; archive
        // targets it via `isMainWorktree` geometry. Surface the
        // `folderIncompatibleAlert` feedback the deeplink layer
        // already shows so hotkeys don't silently no-op.
        if !repository.isGitRepository {
          state.alert = folderIncompatibleAlert(action: .archive)
          return .none
        }
        if state.isMainWorktree(worktree) {
          return .none
        }
        let lifecycle = state.sidebarItems[id: worktree.id]?.lifecycle
        if lifecycle == .deleting || lifecycle == .deletingScript {
          return .none
        }
        if lifecycle == .archiving {
          return .none
        }
        if state.isWorktreeArchived(worktree.id) {
          return .none
        }
        if state.isWorktreeMerged(worktree) {
          return .send(.archiveWorktreeConfirmed(worktree.id, repository.id))
        }
        @Shared(.settingsFile) var settingsFile
        let archivedDisplay =
          AppShortcuts.archivedWorktrees
          .effective(from: settingsFile.global.shortcutOverrides)?.display ?? "none"
        let alertWorktreeName =
          SidebarDisplayName.resolved(
            custom: state.sidebarItems[id: worktree.id]?.customTitle,
            fallback: worktree.name
          ) ?? worktree.name
        state.alert = AlertState {
          TextState("Archive worktree?")
        } actions: {
          ButtonState(role: .destructive, action: .confirmArchiveWorktree(worktree.id, repository.id)) {
            TextState("Archive worktree")
          }
          ButtonState(role: .cancel) {
            TextState("Cancel")
          }
        } message: {
          TextState(
            "You can find \(alertWorktreeName) later in Menu Bar > Worktrees > Archived Worktrees (\(archivedDisplay))."
          )
        }
        return .none

      case .requestArchiveWorktrees(let targets):
        var validTargets: [ArchiveWorktreeTarget] = []
        var seenWorktreeIDs: Set<Worktree.ID> = []
        for target in targets {
          guard seenWorktreeIDs.insert(target.worktreeID).inserted else { continue }
          if state.removingRepositoryIDs[target.repositoryID] != nil {
            continue
          }
          guard let repository = state.repositories[id: target.repositoryID],
            let worktree = repository.worktrees[id: target.worktreeID]
          else {
            continue
          }
          let lifecycle = state.sidebarItems[id: worktree.id]?.lifecycle ?? .idle
          if state.isMainWorktree(worktree)
            || lifecycle != .idle
            || state.isWorktreeArchived(worktree.id)
          {
            continue
          }
          validTargets.append(target)
        }
        guard !validTargets.isEmpty else {
          return .none
        }
        if validTargets.count == 1, let target = validTargets.first {
          return .send(.requestArchiveWorktree(target.worktreeID, target.repositoryID))
        }
        let count = validTargets.count
        @Shared(.settingsFile) var settingsFile
        let archivedDisplay =
          AppShortcuts.archivedWorktrees
          .effective(from: settingsFile.global.shortcutOverrides)?.display ?? "none"
        state.alert = AlertState {
          TextState("Archive \(count) worktrees?")
        } actions: {
          ButtonState(role: .destructive, action: .confirmArchiveWorktrees(validTargets)) {
            TextState("Archive \(count) worktrees")
          }
          ButtonState(role: .cancel) {
            TextState("Cancel")
          }
        } message: {
          TextState(
            "You can find them later in Menu Bar > Worktrees > Archived Worktrees (\(archivedDisplay))."
          )
        }
        return .none

      case .alert(.presented(.confirmArchiveWorktree(let worktreeID, let repositoryID))):
        return .send(.archiveWorktreeConfirmed(worktreeID, repositoryID))

      case .alert(.presented(.confirmArchiveWorktrees(let targets))):
        return .merge(
          targets.map { target in
            .send(.archiveWorktreeConfirmed(target.worktreeID, target.repositoryID))
          }
        )

      case .scriptCompleted(let worktreeID, let kind, let exitCode, let tabId):
        // `runningScripts` reconciles from the terminal's row projection
        // (sole populator), so completion here only surfaces failures.
        guard let exitCode, exitCode != 0 else { return .none }
        state.alert = blockingScriptFailureAlert(
          kind: kind,
          exitCode: exitCode,
          worktreeID: worktreeID,
          tabId: tabId,
          state: state
        )
        return .none

      case .archiveWorktreeConfirmed(let worktreeID, let repositoryID):
        guard let repository = state.repositories[id: repositoryID],
          let worktree = repository.worktrees[id: worktreeID]
        else {
          return .none
        }
        if state.isWorktreeArchived(worktreeID)
          || state.sidebarItems[id: worktreeID]?.lifecycle == .archiving
        {
          state.alert = nil
          return .none
        }
        state.alert = nil
        @Shared(.repositorySettings(worktree.repositoryRootURL, host: worktree.host)) var repositorySettings
        let script = repositorySettings.archiveScript
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        // Orphan rows have no working dir to run a script in; skip
        // straight to the apply step so the cleanup still completes.
        if trimmed.isEmpty || worktree.isMissing {
          return .send(.archiveWorktreeApply(worktreeID, repositoryID))
        }
        return .merge(
          state.setRowLifecycleEffect(worktreeID, .archiving),
          .send(
            .delegate(.runBlockingScript(worktree, repositoryID: repositoryID, kind: .archive, script: script))
          )
        )

      case .archiveScriptCompleted(let worktreeID, let exitCode, let tabId):
        guard state.sidebarItems[id: worktreeID]?.lifecycle == .archiving else {
          repositoriesLogger.debug("Ignoring archiveScriptCompleted for \(worktreeID): not archiving")
          return .none
        }
        let resetLifecycle = state.setRowLifecycleEffect(worktreeID, .idle)
        switch exitCode {
        case 0:
          guard let repositoryID = state.repositoryID(containing: worktreeID) else {
            repositoriesLogger.warning(
              "Archive script succeeded but repository not found for worktree \(worktreeID)"
            )
            state.alert = messageAlert(
              title: "Archive failed",
              message: "The archive script completed successfully, but the worktree could not be found."
                + " It may have been removed."
            )
            return resetLifecycle
          }
          return .merge(resetLifecycle, .send(.archiveWorktreeApply(worktreeID, repositoryID)))
        case nil:
          repositoriesLogger.debug("Archive script cancelled or tab closed for worktree \(worktreeID)")
          return resetLifecycle
        case let code?:
          state.alert = blockingScriptFailureAlert(
            kind: .archive, exitCode: code, worktreeID: worktreeID, tabId: tabId, state: state
          )
          return resetLifecycle
        }

      case .archiveWorktreeApply(let worktreeID, let repositoryID):
        guard let repository = state.repositories[id: repositoryID],
          let worktree = repository.worktrees[id: worktreeID]
        else {
          repositoriesLogger.warning(
            "archiveWorktreeApply: worktree \(worktreeID) not found in repository \(repositoryID)"
          )
          state.alert = messageAlert(
            title: "Archive failed",
            message: "The worktree could not be found. It may have already been removed."
          )
          return .none
        }
        if state.isWorktreeArchived(worktreeID) {
          state.alert = nil
          return .none
        }
        let previousSelection = state.selectedWorktreeID
        let previousSelectedWorktree = state.worktree(for: previousSelection)
        let selectionWasRemoved = state.selectedWorktreeID == worktree.id
        let nextSelection =
          selectionWasRemoved
          ? state.nextWorktreeID(afterRemoving: worktree, in: repository)
          : nil
        withAnimation {
          state.alert = nil
          // Drop the item from its current pinned/unpinned bucket
          // and insert into `.archived` with the timestamp. The
          // seed pass in `reconcileSidebarState` guarantees every
          // live non-main worktree lives in either `.pinned` or
          // `.unpinned` before this runs.
          state.$sidebar.withLock { sidebar in
            let from = sidebar.currentBucket(of: worktreeID, in: repositoryID) ?? .unpinned
            sidebar.archive(worktree: worktreeID, in: repositoryID, from: from, at: now)
          }
          if selectionWasRemoved {
            let nextWorktreeID = nextSelection ?? state.firstAvailableWorktreeID(in: repositoryID)
            state.selection = nextWorktreeID.map(SidebarSelection.worktree)
          }
          Self.syncSidebar(&state)
        }
        let repositories = state.repositories
        let selectedWorktree = state.worktree(for: state.selectedWorktreeID)
        let selectionChanged = state.hasSelectionChanged(
          previousSelectionID: previousSelection,
          previousSelectedWorktree: previousSelectedWorktree,
          selectedWorktreeID: state.selectedWorktreeID,
          selectedWorktree: selectedWorktree,
        )
        var effects: [Effect<Action>] = [
          .send(.delegate(.repositoriesChanged(repositories)))
        ]
        if selectionChanged {
          effects.append(.send(.delegate(.selectedWorktreeChanged(selectedWorktree))))
        }
        return .merge(effects)

      case .unarchiveWorktree(let worktreeID):
        guard let repositoryID = state.repositoryID(containing: worktreeID),
          state.sidebar.sections[repositoryID]?.buckets[.archived]?.items[worktreeID] != nil
        else {
          return .none
        }
        withAnimation {
          state.$sidebar.withLock { sidebar in
            sidebar.unarchive(worktree: worktreeID, in: repositoryID)
          }
          Self.syncSidebar(&state)
        }
        let repositories = state.repositories
        return .send(.delegate(.repositoriesChanged(repositories)))

      case .requestDeleteSidebarItems(let targets):
        // Kind discriminator: folders skip the main-worktree guard
        // (their synthetic worktree IS main). Mixed kind selections
        // get rejected, the context menu already blocks mixed
        // bulk, so this only trips if a hotkey somehow routes a
        // heterogeneous selection here.
        var validTargets: [DeleteWorktreeTarget] = []
        var validKinds: Set<SidebarItemFeature.State.Kind> = []
        var seenWorktreeIDs: Set<Worktree.ID> = []
        var rejectedMainWorktreeCount = 0
        for target in targets {
          guard seenWorktreeIDs.insert(target.worktreeID).inserted,
            state.removingRepositoryIDs[target.repositoryID] == nil,
            let repository = state.repositories[id: target.repositoryID],
            let worktree = repository.worktrees[id: target.worktreeID]
          else { continue }
          let lifecycle = state.sidebarItems[id: worktree.id]?.lifecycle ?? .idle
          guard lifecycle == .idle else { continue }
          if repository.isGitRepository {
            if state.isMainWorktree(worktree) {
              rejectedMainWorktreeCount += 1
              continue
            }
            validKinds.insert(.gitWorktree)
          } else {
            validKinds.insert(.folder)
          }
          validTargets.append(target)
        }
        guard !validTargets.isEmpty, validKinds.count == 1 else {
          // Single-target main-worktree rejection: surface the same
          // "Delete not allowed" feedback the deeplink path already
          // shows, so palette / hotkey / context-menu entries behave
          // consistently instead of silently no-opping.
          if targets.count == 1, validTargets.isEmpty, rejectedMainWorktreeCount == 1 {
            state.alert = messageAlert(
              title: "Delete not allowed",
              message: "Deleting the main worktree is not allowed."
            )
          }
          return .none
        }
        let count = validTargets.count
        if validKinds == [.folder] {
          let folders = validTargets.compactMap { state.repositories[id: $0.repositoryID] }
          let namesList = folders.map(\.name)
            .sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
            .joined(separator: ", ")
          let title = count == 1 ? "Remove folder?" : "Remove \(count) folders?"
          let messageSubject = count == 1 ? folders.first?.name ?? "this folder" : namesList
          let stayOnDiskCopy =
            count == 1
            ? "managing the folder (it stays on disk)"
            : "managing the folders (they stay on disk)"
          let trashCopy =
            count == 1 ? "move the folder to the Trash" : "move them to the Trash"
          state.alert = AlertState {
            TextState(title)
          } actions: {
            ButtonState(
              action: .confirmDeleteSidebarItems(validTargets, disposition: .folderUnlink)
            ) {
              TextState("Remove from Supacode")
            }
            ButtonState(
              role: .destructive,
              action: .confirmDeleteSidebarItems(validTargets, disposition: .folderTrash)
            ) {
              TextState("Delete from disk")
            }
            ButtonState(role: .cancel) {
              TextState("Cancel")
            }
          } message: {
            TextState(
              "Remove \(messageSubject)? Choose \"Remove from Supacode\" to stop "
                + stayOnDiskCopy
                + ", or \"Delete from disk\" to " + trashCopy + "."
            )
          }
          return .none
        }
        @Shared(.settingsFile) var settingsFile
        let deleteBranchOnDeleteWorktree = settingsFile.global.deleteBranchOnDeleteWorktree
        let allMissing = validTargets.allSatisfy { target in
          state.repositories[id: target.repositoryID]?.worktrees[id: target.worktreeID]?.isMissing
            == true
        }
        let title = count == 1 ? "Delete worktree?" : "Delete \(count) worktrees?"
        let buttonLabel = count == 1 ? "Delete worktree" : "Delete \(count) worktrees"
        let message: String =
          switch (count, deleteBranchOnDeleteWorktree, allMissing) {
          case (1, _, true): "Removes the orphan worktree entry from this repository."
          case (_, _, true): "Removes \(count) orphan worktree entries from this repository."
          case (1, true, false): "This deletes the worktree directory and its local branch."
          case (1, false, false): "This deletes the worktree directory but keeps the local branch."
          case (_, true, false):
            "This deletes \(count) worktree directories and their local branches."
          case (_, false, false):
            "This deletes \(count) worktree directories but keeps their local branches."
          }
        state.alert = AlertState {
          TextState(title)
        } actions: {
          ButtonState(
            role: .destructive,
            action: .confirmDeleteSidebarItems(validTargets, disposition: .gitWorktreeDelete)
          ) {
            TextState(buttonLabel)
          }
          ButtonState(role: .cancel) {
            TextState("Cancel")
          }
        } message: {
          TextState(message)
        }
        return .none

      case .alert(.presented(.confirmDeleteSidebarItems(let targets, let disposition))):
        // Kind-and-disposition mapping: folders carry the
        // disposition into `removingRepositoryIDs` so
        // `.deleteScriptCompleted` can route by stored choice later.
        // Git worktrees run the standard per-worktree pipeline and
        // don't record a repo-level disposition. Kind / disposition
        // mismatches are impossible under the current alert surface
        // and a caller bypassing those guards is a bug, so flag it via
        // `reportIssue` instead of dropping silently.
        state.alert = nil
        var validTargets: [DeleteWorktreeTarget] = []
        var folderBatchIDs: Set<Repository.ID> = []
        for target in targets {
          guard let repository = state.repositories[id: target.repositoryID],
            state.removingRepositoryIDs[target.repositoryID] == nil
          else { continue }
          if repository.isGitRepository {
            guard disposition == .gitWorktreeDelete else {
              reportIssue(
                """
                confirmDeleteSidebarItems: received \(disposition) for git worktree \
                \(target.worktreeID): git targets only support .gitWorktreeDelete. \
                Dropping target.
                """
              )
              continue
            }
          } else {
            guard disposition.isFolder else {
              reportIssue(
                """
                confirmDeleteSidebarItems: received \(disposition) for folder \
                \(target.repositoryID): folder targets only support .folderUnlink / \
                .folderTrash. Dropping target.
                """
              )
              continue
            }
            folderBatchIDs.insert(target.repositoryID)
          }
          validTargets.append(target)
        }
        guard !validTargets.isEmpty else { return .none }
        if !folderBatchIDs.isEmpty {
          // All folder targets in this batch share the same
          // disposition (the alert only ever produces one), so one
          // record shape per repo keeps disposition + batch id in
          // lockstep.
          let batchID = uuid()
          for repositoryID in folderBatchIDs {
            state.removingRepositoryIDs[repositoryID] = RepositoryRemovalRecord(
              disposition: disposition, batchID: batchID
            )
          }
          Self.syncSidebar(&state)
          state.activeRemovalBatches[batchID] =
            ActiveRemovalBatch(id: batchID, pending: folderBatchIDs)
        }
        return .merge(
          validTargets.map {
            .send(.deleteSidebarItemConfirmed($0.worktreeID, $0.repositoryID))
          }
        )

      default:
        return .none
      }
    }
  }

  /// Delete / remove worktree + repository handlers, split from `worktreeArchiveReducer` so each
  /// `Reduce` closure stays well under the type-checker's complexity limit.
  var worktreeRemovalReducer: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .deleteSidebarItemConfirmed(let worktreeID, let repositoryID):
        guard let repository = state.repositories[id: repositoryID],
          let worktree = repository.worktrees[id: worktreeID]
        else {
          repositoriesLogger.debug(
            "deleteSidebarItemConfirmed: worktree \(worktreeID) not found in repository \(repositoryID)."
          )
          return .none
        }
        // Lifecycle re-entry guard: only the first tap proceeds; rapid repeats no-op
        // so the aggregator batch isn't double-drained.
        let confirmedLifecycle = state.sidebarItems[id: worktree.id]?.lifecycle ?? .idle
        if confirmedLifecycle == .archiving
          || confirmedLifecycle == .deleting
          || confirmedLifecycle == .deletingScript
        {
          return .none
        }
        // F4: folder targets only arrive here after the alert's
        // confirm handler seeded a `RepositoryRemovalRecord`. If a
        // future caller short-circuits to this action without going
        // through `.requestDeleteSidebarItems` → confirm, the
        // aggregator would never drain. Flag the invariant breach
        // loudly (tests fail, release warns) and bail out early so
        // we don't fall through to the git-worktree delete path for
        // a folder.
        if !repository.isGitRepository,
          state.removingRepositoryIDs[repository.id] == nil
        {
          reportIssue(
            """
            deleteSidebarItemConfirmed: folder \(repository.id) missing seeded removal \
            record. Callers must go through .requestDeleteSidebarItems → \
            .confirmDeleteSidebarItems so the batch aggregator is set up.
            """
          )
          return .none
        }
        // NOTE: we do NOT clear `state.alert` here.
        //   - Alert-confirmed path: `.confirmDeleteSidebarItems`
        //     already cleared its own confirm alert at entry.
        //   - Auto-delete / merged-sweep path: this action fires
        //     programmatically; an unconditional clear here would
        //     wipe unrelated alerts, specifically the consolidated
        //     trash-failure alert just set by the batch aggregator.
        //   - Deeplink path: same, the caller decides alert state.
        @Shared(.repositorySettings(worktree.repositoryRootURL, host: worktree.host)) var repositorySettings
        let script = repositorySettings.deleteScript
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only folder-row intents (`.folderUnlink` / `.folderTrash`)
        // route through the folder-removal success branch.
        // `.gitRepositoryUnlink` is a concurrent git-repo section
        // removal that has no bearing on this worktree's delete flow.
        // `nil` is a git worktree delete (no repo-level intent).
        let folderIntent: DeleteDisposition? = {
          guard let record = state.removingRepositoryIDs[repository.id],
            record.disposition.isFolder
          else { return nil }
          return record.disposition
        }()
        // Orphan rows have no working dir to run a script in; skip the
        // script and apply the delete directly so the cleanup completes.
        if trimmed.isEmpty || worktree.isMissing {
          if let folderIntent {
            // Empty script: finish the folder flow immediately,
            // trashing the directory first if the user asked for it.
            let selectionWasRemoved = state.selectedWorktreeID == worktreeID
            let trashURL = folderIntent == .folderTrash ? repository.rootURL : nil
            return .merge(
              state.setRowLifecycleEffect(worktree.id, .deleting),
              folderRemovalEffect(
                repositoryID: repository.id,
                selectionWasRemoved: selectionWasRemoved,
                diskDeletionURL: trashURL
              )
            )
          }
          return .send(.deleteWorktreeApply(worktreeID, repositoryID))
        }
        return .merge(
          state.setRowLifecycleEffect(worktree.id, .deletingScript),
          .send(
            .delegate(.runBlockingScript(worktree, repositoryID: repositoryID, kind: .delete, script: script))
          )
        )

      case .deleteScriptCompleted(let worktreeID, let exitCode, let tabId):
        guard state.sidebarItems[id: worktreeID]?.lifecycle == .deletingScript else {
          repositoriesLogger.debug(
            "Ignoring deleteScriptCompleted for \(worktreeID): not running a delete script."
          )
          return .none
        }
        let resetLifecycle = state.setRowLifecycleEffect(worktreeID, .idle)
        // Route by recorded intent, not live classification: a
        // `git init` mid-script would otherwise flip the check and
        // lose folder intent. Kind divergence is treated as an
        // explicit error so the user can decide what to do.
        let owningRepo = state.repositories.first(where: {
          $0.worktrees.contains(where: { $0.id == worktreeID })
        })
        // Only a folder-row intent (`.folderUnlink` / `.folderTrash`)
        // routes this completion into repo-level removal.
        // `.gitRepositoryUnlink` is a concurrent git-repo remove
        // running independently; it shouldn't hijack the
        // worktree-delete pipeline. `nil` means plain git worktree
        // delete.
        let folderIntent: DeleteDisposition? =
          owningRepo
          .flatMap { state.removingRepositoryIDs[$0.id] }
          .flatMap { $0.disposition.isFolder ? $0.disposition : nil }
        let followupEffect: Effect<Action>
        switch exitCode {
        case 0:
          if let folderIntent, let owningRepo {
            if owningRepo.isGitRepository {
              // Kind flipped between confirmation and completion. Bail out
              // rather than silently picking a path.
              state.alert = messageAlert(
                title: "Folder is now a git repository",
                message: "Supacode stopped the removal because \(owningRepo.name) became a git "
                  + "repository while the delete script was running. Review it and try again."
              )
              followupEffect = signalFolderRemovalFailure(worktreeID: worktreeID, state: &state)
            } else {
              let selectionWasRemoved = state.selectedWorktreeID == worktreeID
              let trashURL = folderIntent == .folderTrash ? owningRepo.rootURL : nil
              followupEffect = folderRemovalEffect(
                repositoryID: owningRepo.id,
                selectionWasRemoved: selectionWasRemoved,
                diskDeletionURL: trashURL
              )
            }
          } else if let repositoryID = state.repositoryID(containing: worktreeID) {
            followupEffect = .send(.deleteWorktreeApply(worktreeID, repositoryID))
          } else if state.removingRepositoryIDs[RepositoryID(worktreeID.rawValue)]?.disposition.isFolder
            == true
          {
            // Synthetic folder id + open folder record: drain the aggregator
            // so siblings don't hang. Only surface the alert when no folder
            // record exists.
            repositoriesLogger.warning(
              "Delete script succeeded but repository vanished for folder worktree "
                + "\(worktreeID); draining batch as failure."
            )
            followupEffect = signalFolderRemovalFailure(worktreeID: worktreeID, state: &state)
          } else {
            repositoriesLogger.warning(
              "Delete script succeeded but repository not found for worktree \(worktreeID)"
            )
            state.alert = messageAlert(
              title: "Delete failed",
              message: "The delete script completed successfully, but the worktree could not be found."
                + " It may have been removed."
            )
            followupEffect = .none
          }
        case nil:
          // User closed the script tab.
          repositoriesLogger.debug(
            "Delete script cancelled or tab closed for worktree \(worktreeID).")
          followupEffect = signalFolderRemovalFailure(worktreeID: worktreeID, state: &state)
        case let code?:
          // Script failed. Show the standard failure alert AND for folder
          // removals signal the aggregator so bulk batches don't hang.
          // Git worktree delete has no batch.
          state.alert = blockingScriptFailureAlert(
            kind: .delete, exitCode: code, worktreeID: worktreeID, tabId: tabId, state: state
          )
          followupEffect = signalFolderRemovalFailure(worktreeID: worktreeID, state: &state)
        }
        return .merge(resetLifecycle, followupEffect)

      case .deleteWorktreeApply(let worktreeID, let repositoryID):
        guard let repository = state.repositories[id: repositoryID],
          let worktree = repository.worktrees[id: worktreeID]
        else {
          repositoriesLogger.warning(
            "deleteWorktreeApply: worktree \(worktreeID) not found in repository \(repositoryID)"
          )
          state.alert = messageAlert(
            title: "Delete failed",
            message: "The worktree could not be found. It may have already been removed."
          )
          return .none
        }
        let selectionWasRemoved = state.selectedWorktreeID == worktree.id
        let nextSelection =
          selectionWasRemoved
          ? state.nextWorktreeID(afterRemoving: worktree, in: repository)
          : nil
        @Shared(.settingsFile) var settingsFile
        let deleteBranchOnDeleteWorktree = settingsFile.global.deleteBranchOnDeleteWorktree
        // Host-aware: a remote worktree is removed via `git worktree remove`
        // over ssh on the host, not against the local checkout.
        let deleteClient = gitClient(for: worktree)
        return .merge(
          state.setRowLifecycleEffect(worktree.id, .deleting),
          .run { send in
            do {
              _ = try await deleteClient.removeWorktree(
                worktree,
                deleteBranchOnDeleteWorktree
              )
              await send(
                .worktreeDeleted(
                  worktree.id,
                  repositoryID: repository.id,
                  selectionWasRemoved: selectionWasRemoved,
                  nextSelection: nextSelection
                )
              )
            } catch {
              await send(.deleteWorktreeFailed(error.localizedDescription, worktreeID: worktree.id))
            }
          }
        )

      case .worktreeDeleted(
        let worktreeID,
        let repositoryID,
        _,
        let nextSelection
      ):
        analyticsClient.capture("worktree_deleted", nil)
        let previousSelection = state.selectedWorktreeID
        let previousSelectedWorktree = state.worktree(for: previousSelection)
        withAnimation(.easeOut(duration: 0.2)) {
          state.pendingWorktrees.removeAll { $0.id == worktreeID }
          state.resetRowLifecycleSyncBeforeReconcile(itemID: worktreeID)
          // Drop the worktree from every bucket in its section. The worktree is
          // going away entirely so its current bucket doesn't matter.
          _ = state.$sidebar.withLock { sidebar in
            sidebar.removeAnywhere(worktree: worktreeID, in: repositoryID)
          }
          _ = state.removeWorktree(worktreeID, repositoryID: repositoryID)
          let selectionNeedsUpdate = state.selection == .worktree(worktreeID)
          if selectionNeedsUpdate {
            let nextWorktreeID = nextSelection ?? state.firstAvailableWorktreeID(in: repositoryID)
            state.selection = nextWorktreeID.map(SidebarSelection.worktree)
          }
          Self.syncSidebar(&state)
        }
        let roots = state.repositories.map(\.rootURL)
        let repositories = state.repositories
        let selectedWorktree = state.worktree(for: state.selectedWorktreeID)
        let selectionChanged = state.hasSelectionChanged(
          previousSelectionID: previousSelection,
          previousSelectedWorktree: previousSelectedWorktree,
          selectedWorktreeID: state.selectedWorktreeID,
          selectedWorktree: selectedWorktree,
        )
        var immediateEffects: [Effect<Action>] = [
          .send(.delegate(.repositoriesChanged(repositories)))
        ]
        if selectionChanged {
          immediateEffects.append(.send(.delegate(.selectedWorktreeChanged(selectedWorktree))))
        }
        let followupEffects: [Effect<Action>] = [
          roots.isEmpty ? .none : .send(.reloadRepositories(animated: true))
        ]
        return .concatenate(
          .merge(immediateEffects),
          .merge(followupEffects)
        )

      case .repositoriesMoved(let offsets, let destination):
        var ordered = state.orderedRepositoryIDs()
        guard !offsets.isEmpty, ordered.indices.contains(offsets.min() ?? 0),
          destination <= ordered.count
        else { return .none }
        ordered.move(fromOffsets: offsets, toOffset: destination)
        withAnimation(.snappy(duration: 0.2)) {
          state.$sidebar.withLock { sidebar in
            var reordered: OrderedDictionary<Repository.ID, SidebarState.Section> = [:]
            for id in ordered {
              reordered[id] = sidebar.sections[id] ?? .init()
            }
            // Sections for repos still loading / not yet seen are
            // reliably absent from `ordered`; append them in their
            // original relative order so a live-row reorder doesn't
            // silently reshuffle curation on them.
            for (id, section) in sidebar.sections where reordered[id] == nil {
              reordered[id] = section
            }
            sidebar.sections = reordered
          }
        }
        return .none

      case .pinnedWorktreesMoved(let repositoryID, let offsets, let destination):
        guard let repository = state.repositories[id: repositoryID] else { return .none }
        let currentPinned = state.orderedPinnedWorktreeIDs(in: repository)
        guard currentPinned.count > 1 else { return .none }
        var reordered = currentPinned
        reordered.move(fromOffsets: offsets, toOffset: destination)
        withAnimation(.snappy(duration: 0.2)) {
          state.$sidebar.withLock { sidebar in
            sidebar.reorder(bucket: .pinned, in: repositoryID, to: reordered)
          }
          RepositoriesFeature.syncSidebar(&state)
        }
        return .none

      case .unpinnedWorktreesMoved(let repositoryID, let offsets, let destination):
        guard let repository = state.repositories[id: repositoryID] else { return .none }
        let currentUnpinned = state.orderedUnpinnedWorktreeIDs(in: repository)
        guard currentUnpinned.count > 1 else { return .none }
        var reordered = currentUnpinned
        reordered.move(fromOffsets: offsets, toOffset: destination)
        withAnimation(.snappy(duration: 0.2)) {
          state.$sidebar.withLock { sidebar in
            sidebar.reorder(bucket: .unpinned, in: repositoryID, to: reordered)
          }
          RepositoriesFeature.syncSidebar(&state)
        }
        return .none

      case .deleteWorktreeFailed(let message, let worktreeID):
        state.alert = messageAlert(title: "Unable to delete worktree", message: message)
        guard state.sidebarItems[id: worktreeID]?.lifecycle == .deleting else { return .none }
        return state.setRowLifecycleEffect(worktreeID, .idle)

      case .requestDeleteRepository(let repositoryID):
        // Remote repos aren't on disk locally, so removing one just drops its
        // persisted config + reloads; the remote files are untouched. No
        // local-removal confirmation flow.
        if state.repositories[id: repositoryID]?.host != nil {
          return .send(.removeRemoteRepository(repositoryID))
        }
        state.alert = confirmationAlertForRepositoryRemoval(repositoryID: repositoryID, state: state)
        return .none

      case .requestRemoveFailedRepository(let repositoryID):
        state.alert = confirmationAlertForFailedRepositoryRemoval(
          repositoryID: repositoryID, state: state
        )
        return .none

      case .removeFailedRepository(let repositoryID):
        state.loadFailuresByID.removeValue(forKey: repositoryID)
        state.repositoryRoots.removeAll {
          RepositoryID($0.standardizedFileURL.path(percentEncoded: false)) == repositoryID
        }
        // Drop persisted customization so re-adding the same path doesn't
        // silently restore the old title/color, matching the healthy-repo path.
        state.$sidebar.withLock { sidebar in
          _ = sidebar.sections.removeValue(forKey: repositoryID)
        }
        state.dropStaleFailedRepositorySelection()
        return .run { send in
          let loadedPaths = await repositoryPersistence.loadRoots()
          var seen: Set<String> = []
          let rootPaths = loadedPaths.filter { seen.insert($0).inserted }
          let remaining = rootPaths.filter { $0 != repositoryID.rawValue }
          await repositoryPersistence.saveRoots(remaining)
          await repositoryPersistence.pruneRepositoryConfigs([repositoryID.rawValue])
          let roots = remaining.map { URL(fileURLWithPath: $0) }
          let loadResult = await loadRepositoriesData(roots)
          await send(.gitEnvironmentChanged(loadResult.environmentError))
          await send(
            .repositoriesLoaded(
              loadResult.repositories,
              failures: loadResult.failures,
              roots: roots,
              animated: true
            )
          )
        }
        .cancellable(id: CancelID.load, cancelInFlight: true)

      case .alert(.presented(.confirmRemoveFailedRepository(let repositoryID))):
        state.alert = nil
        return .send(.removeFailedRepository(repositoryID))

      case .alert(.presented(.confirmDeleteRepository(let repositoryID))):
        guard let repository = state.repositories[id: repositoryID] else {
          return .none
        }
        if state.removingRepositoryIDs[repository.id] != nil {
          return .none
        }
        state.alert = nil
        // Section-level removal: Supacode never nukes a git repo's
        // on-disk state. No script runs; signal completion
        // immediately and let the aggregator (batch of 1) emit the
        // terminal.
        let selectionWasRemoved =
          state.selectedWorktreeID.map { id in
            repository.worktrees.contains(where: { $0.id == id })
          } ?? false
        let batchID = uuid()
        state.removingRepositoryIDs[repository.id] = RepositoryRemovalRecord(
          disposition: .gitRepositoryUnlink, batchID: batchID
        )
        Self.syncSidebar(&state)
        state.activeRemovalBatches[batchID] =
          ActiveRemovalBatch(id: batchID, pending: [repository.id])
        return .send(
          .repositoryRemovalCompleted(
            repository.id, outcome: .success, selectionWasRemoved: selectionWasRemoved))

      case .repositoryRemovalCompleted(
        let repositoryID, let outcome, let selectionWasRemoved):
        // Aggregator entry point. Every repo-level removal
        // (successful or not) drains through here so bulk batches
        // fire a single terminal `.repositoriesRemoved` after the
        // last target reports in. `.failure` outcomes keep the
        // batch progressing past failures without removing the
        // repo from state.
        guard let record = state.removingRepositoryIDs[repositoryID],
          var batch = state.activeRemovalBatches[record.batchID]
        else {
          // Orphaned completion: every sender seeds the record +
          // batch before signalling, so arriving here means a bug
          // (e.g. future caller skipped setup). Surface it loudly
          // via `reportIssue` so tests fail and release builds emit
          // a warning, and defensively clean up any state the
          // absent terminal would otherwise leave hanging.
          reportIssue(
            """
            repositoryRemovalCompleted: no active batch for \(repositoryID). \
            This indicates an invariant violation: every confirm handler \
            must seed a batch before per-target work fires.
            """
          )
          state.removingRepositoryIDs[repositoryID] = nil
          // Narrow the cleanup to the folder-synthetic worktree id so a future
          // caller passing a git repo id here can't disturb sibling-worktree state.
          let orphanFolderWorktreeID = Repository.folderWorktreeID(
            for: URL(fileURLWithPath: repositoryID.rawValue)
          )
          switch outcome {
          case .success:
            return .send(
              .repositoriesRemoved([repositoryID], selectionWasRemoved: selectionWasRemoved))
          case .failureSilent:
            return state.clearFolderRowLifecycleEffect(orphanFolderWorktreeID)
          case .failureWithMessage(let message):
            state.alert = messageAlert(
              title: "Delete from disk failed", message: message
            )
            return state.clearFolderRowLifecycleEffect(orphanFolderWorktreeID)
          }
        }
        let batchID = record.batchID
        batch.pending.remove(repositoryID)
        batch.selectionWasRemoved = batch.selectionWasRemoved || selectionWasRemoved
        // Failure cleanup is scoped to the folder-synthetic worktree id because only
        // folder dispositions reach a failure completion. Git repo unlink hardcodes success.
        let folderWorktreeIDForFailure: Worktree.ID? =
          record.disposition.isFolder
          ? Repository.folderWorktreeID(for: URL(fileURLWithPath: repositoryID.rawValue))
          : nil
        var rowEffects: [Effect<Action>] = []
        switch outcome {
        case .success:
          batch.succeeded.append(repositoryID)
        // `.repositoriesRemoved` clears `removingRepositoryIDs`
        // for the successful targets as part of the terminal,
        // leave the record in place so the UI keeps showing the
        // "removing" indicator until then.
        case .failureSilent:
          state.removingRepositoryIDs[repositoryID] = nil
          if let folderWorktreeIDForFailure {
            rowEffects.append(state.clearFolderRowLifecycleEffect(folderWorktreeIDForFailure))
          }
          batch.hasSilentFailure = true
        case .failureWithMessage(let message):
          state.removingRepositoryIDs[repositoryID] = nil
          if let folderWorktreeIDForFailure {
            rowEffects.append(state.clearFolderRowLifecycleEffect(folderWorktreeIDForFailure))
          }
          batch.failureMessagesByRepositoryID[repositoryID] = message
        }
        if batch.pending.isEmpty {
          state.activeRemovalBatches[batchID] = nil
          // Consolidated failure alert: when any target in the
          // batch reported a `.failureWithMessage`, surface one
          // alert listing them. Avoids parallel `.presentAlert`
          // races where the last trash failure overwrites the
          // others.
          //
          // When a `.failureSilent` target in the same batch has
          // already set `state.alert` directly (blocking-script
          // failure / user cancel / kind-flip), preserve the
          // caller's alert and log the trash failures instead of
          // clobbering. macOS only shows one alert at a time, and
          // the script-failure alert carries actionable context
          // (the "View Terminal" button) that the consolidated
          // trash alert does not.
          if !batch.failureMessagesByRepositoryID.isEmpty {
            if batch.hasSilentFailure {
              for (id, message) in batch.failureMessagesByRepositoryID {
                let name = state.repositories[id: id]?.name ?? id.rawValue
                repositoriesLogger.warning(
                  "Trash failure for \(name) (\(id)) suppressed "
                    + "(silent-failure alert already showing for sibling target): \(message)"
                )
              }
            } else {
              // Resolve names NOW (while `state.repositories`
              // still has every batch member) so the alert stays
              // user-recognizable even if the downstream
              // `.repositoriesRemoved` → `.repositoriesLoaded`
              // reloads prune an entry before the alert is read.
              var namesByRepositoryID: [Repository.ID: String] = [:]
              for id in batch.failureMessagesByRepositoryID.keys {
                if let name = state.repositories[id: id]?.name {
                  namesByRepositoryID[id] = name
                }
              }
              state.alert = consolidatedTrashFailureAlert(
                failureMessagesByRepositoryID: batch.failureMessagesByRepositoryID,
                namesByRepositoryID: namesByRepositoryID
              )
            }
          }
          guard !batch.succeeded.isEmpty else {
            return .merge(rowEffects)
          }
          rowEffects.append(
            .send(
              .repositoriesRemoved(
                batch.succeeded, selectionWasRemoved: batch.selectionWasRemoved))
          )
          return .merge(rowEffects)
        }
        state.activeRemovalBatches[batchID] = batch
        return .merge(rowEffects)

      case .repositoriesRemoved(let repositoryIDs, let selectionWasRemoved):
        // Bulk terminal: mutates `repositories` / `repositoryRoots`
        // synchronously, emits one `.repositoriesLoaded` for
        // reconciliation and a single cancellable persistence save.
        // Firing once per batch (instead of once per target) removes
        // the reload race.
        guard !repositoryIDs.isEmpty else { return .none }
        let idSet = Set(repositoryIDs)
        for id in repositoryIDs {
          let kind = (state.repositories[id: id]?.isGitRepository ?? true) ? "git" : "folder"
          analyticsClient.capture("repository_removed", ["kind": kind])
          state.removingRepositoryIDs[id] = nil
        }
        state.resetRowLifecycleSyncBeforeReconcile(inRepositories: idSet)
        if selectionWasRemoved {
          state.selection = nil
          state.shouldSelectFirstAfterReload = true
        }
        // Drop sidebar sections for explicitly-removed repos before
        // reconcile fires. `preserveOrphanSections` keeps customized
        // tombstones across transient drops (filesystem flutter), but
        // an explicit "Remove Repository" must not silently restore
        // the user's old title / color when the same path is re-added
        // later.
        state.$sidebar.withLock { sidebar in
          for id in repositoryIDs {
            sidebar.sections.removeValue(forKey: id)
          }
        }
        let selectedWorktree = state.worktree(for: state.selectedWorktreeID)
        let remainingRepositories = Array(state.repositories.filter { !idSet.contains($0.id) })
        let remainingRoots = state.repositoryRoots.filter {
          !idSet.contains(RepositoryID($0.standardizedFileURL.path(percentEncoded: false)))
        }
        let remainingFailures = state.loadFailuresByID
          .filter { !idSet.contains($0.key) }
          .map { LoadFailure(rootID: $0.key, message: $0.value) }
        let pathsToPersist = remainingRoots.map {
          $0.standardizedFileURL.path(percentEncoded: false)
        }
        let removedIDs = Array(idSet)
        return .merge(
          .send(.delegate(.selectedWorktreeChanged(selectedWorktree))),
          .send(
            .repositoriesLoaded(
              remainingRepositories,
              failures: remainingFailures,
              roots: remainingRoots,
              animated: true
            )
          ),
          .run { _ in
            // `saveRoots` replaces the `repositoryRoots` array with
            // the pruned list; `pruneRepositoryConfigs` drops the
            // `repositories` dict entries (scripts / run config /
            // open action) for repos that just left. Without the
            // second step those entries pile up forever,
            // especially visible for folder repos that users add +
            // remove while exploring.
            await repositoryPersistence.saveRoots(pathsToPersist)
            await repositoryPersistence.pruneRepositoryConfigs(removedIDs.map(\.rawValue))
          }
          .cancellable(id: CancelID.persistRoots, cancelInFlight: true)
        )
      default:
        return .none
      }
    }
  }

  /// `createWorktreeInRepository` is the single heaviest action arm; it lives in its own reducer
  /// so `body` stays under the Swift type-checker's complexity limit.
  var worktreeCreateInRepoReducer: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .createWorktreeInRepository(
        let repositoryID,
        let nameSource,
        let baseRefSource,
        let fetchOrigin,
        let placement,
        let providedPendingID
      ):
        // Pull the parked branch name so every rejection arm can drain its (repo, branch) entry
        // through the same helper — keeps the dict from leaking when a creation is rejected via
        // any of the three guards below.
        let rejectedBranchName: String? = if case .explicit(let name) = nameSource { name } else { nil }
        guard let repository = state.repositories[id: repositoryID] else {
          state.alert = messageAlert(
            title: "Unable to create worktree",
            message: "Unable to resolve a repository for the new worktree."
          )
          if let rejectedBranchName {
            state.dropPendingCustomization(repositoryID: repositoryID, branchName: rejectedBranchName)
          }
          return .none
        }
        // Guard against folder-kind entries arriving here via deeplink / palette paths that bypass
        // `.createRandomWorktreeInRepository`.
        if !repository.isGitRepository {
          state.alert = messageAlert(
            title: "Unable to create worktree",
            message: "Worktrees are only supported for git repositories."
          )
          if let rejectedBranchName {
            state.dropPendingCustomization(repositoryID: repository.id, branchName: rejectedBranchName)
          }
          return .none
        }
        // Remote repos create worktrees over ssh via `git worktree add`, then
        // reload to re-list. This bypasses the local pending/stream flow below,
        // but honors the same name + base-ref choices from the prompt.
        if repository.host != nil {
          return remoteCreateWorktree(
            repository: repository,
            nameSource: nameSource,
            baseRefSource: baseRefSource,
            fetchOrigin: fetchOrigin,
            placement: placement
          )
        }
        if state.removingRepositoryIDs[repository.id] != nil {
          state.alert = messageAlert(
            title: "Unable to create worktree",
            message: "This repository is being removed."
          )
          // Creation is being rejected; drop just the in-flight (repo, branch) entry so other
          // concurrent customizations for this repo aren't wiped out.
          if let rejectedBranchName {
            state.dropPendingCustomization(repositoryID: repository.id, branchName: rejectedBranchName)
          }
          return .none
        }
        let previousSelection = state.selectedWorktreeID
        // Honor a deeplink-supplied pending id so a CLI completion ack can
        // correlate this exact creation through to its success / failure.
        let pendingID = providedPendingID ?? WorktreeID("\(WorktreeID.pendingPrefix)\(uuid().uuidString)")
        @Shared(.settingsFile) var settingsFile
        @Shared(.repositorySettings(repository.rootURL, host: repository.host)) var repositorySettings
        let globalDefaultWorktreeBaseDirectoryPath = settingsFile.global.defaultWorktreeBaseDirectoryPath
        let worktreeBaseDirectory = SupacodePaths.worktreeBaseDirectory(
          for: repository.rootURL,
          globalDefaultPath: globalDefaultWorktreeBaseDirectoryPath,
          repositoryOverridePath: repositorySettings.worktreeBaseDirectoryPath
        )
        let selectedBaseRef = repositorySettings.worktreeBaseRef
        let globalSettings = settingsFile.global
        let copyIgnoredOnWorktreeCreate =
          repositorySettings.copyIgnoredOnWorktreeCreate ?? globalSettings.copyIgnoredOnWorktreeCreate
        let copyUntrackedOnWorktreeCreate =
          repositorySettings.copyUntrackedOnWorktreeCreate ?? globalSettings.copyUntrackedOnWorktreeCreate
        let initialWorktreeName: String? = if case .explicit(let name) = nameSource { name } else { nil }
        // Pull any customization the New Worktree prompt parked for this
        // (repo, branch) and attach it to the pending row so reconcile
        // can render the user-typed title / color while git creates the
        // worktree. Drop the dict entry to avoid leaks if the same name
        // is used in a later run.
        let pendingCustomization: PendingWorktree.Customization?
        if let initialWorktreeName {
          pendingCustomization = state.pendingCreationCustomizations[repository.id]?[initialWorktreeName]
          state.dropPendingCustomization(repositoryID: repository.id, branchName: initialWorktreeName)
        } else {
          pendingCustomization = nil
        }
        state.pendingWorktrees.append(
          PendingWorktree(
            id: pendingID,
            repositoryID: repository.id,
            progress: WorktreeCreationProgress(stage: .loadingLocalBranches, worktreeName: initialWorktreeName),
            customization: pendingCustomization
          )
        )
        Self.syncSidebar(&state)
        state.setSingleWorktreeSelection(pendingID)
        let existingNames = Set(repository.worktrees.map { $0.name.lowercased() })
        let createWorktreeStream = gitClient.createWorktreeStream
        let isValidBranchName = gitClient.isValidBranchName
        return .run { send in
          var newWorktreeName: String?
          var progress = WorktreeCreationProgress(
            stage: .loadingLocalBranches,
            worktreeName: initialWorktreeName
          )
          var progressUpdateThrottle = WorktreeCreationProgressUpdateThrottle(
            stride: worktreeCreationProgressUpdateStride
          )
          do {
            await send(
              .pendingWorktreeProgressUpdated(
                id: pendingID,
                progress: progress
              )
            )
            let branchNames = try await gitClient.localBranchNames(repository.rootURL)
            let existing = existingNames.union(branchNames)
            let name: String
            switch nameSource {
            case .random:
              progress.stage = .choosingWorktreeName
              await send(
                .pendingWorktreeProgressUpdated(
                  id: pendingID,
                  progress: progress
                )
              )
              let generatedName = await MainActor.run {
                WorktreeNameGenerator.nextName(excluding: existing)
              }
              guard let generatedName else {
                let message =
                  "All default adjective-animal names are already in use. "
                  + "Delete a worktree or rename a branch, then try again."
                await send(
                  .createRandomWorktreeFailed(
                    title: "No available worktree names",
                    message: message,
                    pendingID: pendingID,
                    previousSelection: previousSelection,
                    repositoryID: repository.id,
                    name: nil,
                    baseDirectory: worktreeBaseDirectory
                  )
                )
                return
              }
              name = generatedName
            case .explicit(let explicitName):
              let trimmed = explicitName.trimmingCharacters(in: .whitespacesAndNewlines)
              guard !trimmed.isEmpty else {
                await send(
                  .createRandomWorktreeFailed(
                    title: "Branch name required",
                    message: "Enter a branch name to create a worktree.",
                    pendingID: pendingID,
                    previousSelection: previousSelection,
                    repositoryID: repository.id,
                    name: nil,
                    baseDirectory: worktreeBaseDirectory
                  )
                )
                return
              }
              guard !trimmed.contains(where: \.isWhitespace) else {
                await send(
                  .createRandomWorktreeFailed(
                    title: "Branch name invalid",
                    message: "Branch names can't contain spaces.",
                    pendingID: pendingID,
                    previousSelection: previousSelection,
                    repositoryID: repository.id,
                    name: nil,
                    baseDirectory: worktreeBaseDirectory
                  )
                )
                return
              }
              guard await isValidBranchName(trimmed, repository.rootURL) else {
                await send(
                  .createRandomWorktreeFailed(
                    title: "Branch name invalid",
                    message: "Enter a valid git branch name and try again.",
                    pendingID: pendingID,
                    previousSelection: previousSelection,
                    repositoryID: repository.id,
                    name: nil,
                    baseDirectory: worktreeBaseDirectory
                  )
                )
                return
              }
              guard !existing.contains(trimmed.lowercased()) else {
                await send(
                  .createRandomWorktreeFailed(
                    title: "Branch name already exists",
                    message: "Choose a different branch name and try again.",
                    pendingID: pendingID,
                    previousSelection: previousSelection,
                    repositoryID: repository.id,
                    name: nil,
                    baseDirectory: worktreeBaseDirectory
                  )
                )
                return
              }
              name = trimmed
            }
            newWorktreeName = name
            // Validate the name leaf here too: the prompt guards it, but the
            // CLI / deeplink entry points reach this path without that check.
            if let nameError = WorktreePlacementOverride.nameValidationError(placement?.name) {
              await send(
                .createRandomWorktreeFailed(
                  title: "Worktree name invalid",
                  message: nameError,
                  pendingID: pendingID,
                  previousSelection: previousSelection,
                  repositoryID: repository.id,
                  name: nil,
                  baseDirectory: worktreeBaseDirectory
                )
              )
              return
            }
            let worktreeDirectoryURL = SupacodePaths.resolvedWorktreeDirectory(
              defaultBaseDirectory: worktreeBaseDirectory,
              repositoryRootURL: repository.rootURL,
              nameOverride: placement?.name,
              pathOverride: placement?.path,
              branchName: name
            )
            progress.worktreeName = name
            progress.stage = .checkingRepositoryMode
            await send(
              .pendingWorktreeProgressUpdated(
                id: pendingID,
                progress: progress
              )
            )
            let isBareRepository = (try? await gitClient.isBareRepository(repository.rootURL)) ?? false
            let copyIgnored = isBareRepository ? false : copyIgnoredOnWorktreeCreate
            let copyUntracked = isBareRepository ? false : copyUntrackedOnWorktreeCreate
            progress.stage = .resolvingBaseReference
            await send(
              .pendingWorktreeProgressUpdated(
                id: pendingID,
                progress: progress
              )
            )
            let resolvedBaseRef: String
            switch baseRefSource {
            case .repositorySetting:
              if (selectedBaseRef ?? "").isEmpty {
                resolvedBaseRef = await gitClient.automaticWorktreeBaseRef(repository.rootURL) ?? ""
              } else {
                resolvedBaseRef = selectedBaseRef ?? ""
              }
            case .explicit(let explicitBaseRef):
              if let explicitBaseRef, !explicitBaseRef.isEmpty {
                resolvedBaseRef = explicitBaseRef
              } else {
                resolvedBaseRef = await gitClient.automaticWorktreeBaseRef(repository.rootURL) ?? ""
              }
            }
            progress.baseRef = resolvedBaseRef
            if fetchOrigin {
              let remotes: [String]
              do {
                remotes = try await gitClient.remoteNames(repository.rootURL)
              } catch {
                let repoPath = repository.rootURL.path(percentEncoded: false)
                repositoriesLogger.warning(
                  "git remote listing failed for \(repoPath): \(error.localizedDescription)"
                )
                remotes = []
              }
              let matchedRemote = resolvedBaseRef.matchingRemote(from: remotes)
              if let matchedRemote {
                progress.fetchRemoteName = matchedRemote
                progress.stage = .fetchingOrigin
                await send(
                  .pendingWorktreeProgressUpdated(
                    id: pendingID,
                    progress: progress
                  )
                )
                do {
                  try await gitClient.fetchRemote(matchedRemote, repository.rootURL)
                } catch {
                  repositoriesLogger.warning(
                    "git fetch \(matchedRemote) failed for \(repository.rootURL.path(percentEncoded: false)): \(error)"
                  )
                  progress.appendOutputLine(
                    "Fetch failed: \(error.localizedDescription)",
                    maxLines: worktreeCreationProgressLineLimit
                  )
                  await send(
                    .pendingWorktreeProgressUpdated(id: pendingID, progress: progress)
                  )
                }
              } else {
                repositoriesLogger.debug(
                  "Skipping fetch: no matching remote for base ref '\(resolvedBaseRef)'"
                )
              }
            }
            progress.copyIgnored = copyIgnored
            progress.copyUntracked = copyUntracked
            progress.ignoredFilesToCopyCount =
              copyIgnored ? ((try? await gitClient.ignoredFileCount(repository.rootURL)) ?? 0) : 0
            progress.untrackedFilesToCopyCount =
              copyUntracked ? ((try? await gitClient.untrackedFileCount(repository.rootURL)) ?? 0) : 0
            progress.stage = .creatingWorktree
            progress.commandText = worktreeCreateCommand(
              baseDirectoryURL: worktreeBaseDirectory,
              name: name,
              copyFiles: (ignored: copyIgnored, untracked: copyUntracked),
              baseRef: resolvedBaseRef,
              directoryOverride: worktreeDirectoryURL
            )
            await send(
              .pendingWorktreeProgressUpdated(
                id: pendingID,
                progress: progress
              )
            )
            let stream = createWorktreeStream(
              name,
              repository.rootURL,
              worktreeBaseDirectory,
              copyIgnored,
              copyUntracked,
              resolvedBaseRef,
              worktreeDirectoryURL
            )
            for try await event in stream {
              switch event {
              case .outputLine(let outputLine):
                let line = outputLine.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else {
                  continue
                }
                progress.appendOutputLine(line, maxLines: worktreeCreationProgressLineLimit)
                if progressUpdateThrottle.recordLine() {
                  await send(
                    .pendingWorktreeProgressUpdated(
                      id: pendingID,
                      progress: progress
                    )
                  )
                }
              case .finished(let newWorktree):
                if progressUpdateThrottle.flush() {
                  await send(
                    .pendingWorktreeProgressUpdated(
                      id: pendingID,
                      progress: progress
                    )
                  )
                }
                await send(
                  .createRandomWorktreeSucceeded(
                    newWorktree,
                    repositoryID: repository.id,
                    pendingID: pendingID
                  )
                )
                return
              }
            }
            throw GitClientError.commandFailed(
              command: "wt sw",
              message: "Worktree creation finished without a result."
            )
          } catch {
            if progressUpdateThrottle.flush() {
              await send(
                .pendingWorktreeProgressUpdated(
                  id: pendingID,
                  progress: progress
                )
              )
            }
            await send(
              .createRandomWorktreeFailed(
                title: "Unable to create worktree",
                message: error.localizedDescription,
                pendingID: pendingID,
                previousSelection: previousSelection,
                repositoryID: repository.id,
                name: newWorktreeName,
                baseDirectory: worktreeBaseDirectory
              )
            )
          }
        }
      default:
        return .none
      }
    }
  }

  /// GitHub availability + pull-request + worktree-info-loaded handlers, split from `body` so each
  /// `Reduce` closure stays under the type-checker's complexity limit.
  var githubIntegrationReducer: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .refreshGithubIntegrationAvailability:
        guard state.githubIntegrationAvailability != .checking,
          state.githubIntegrationAvailability != .disabled
        else {
          return .none
        }
        state.githubIntegrationAvailability = .checking
        let githubIntegration = githubIntegration
        return .run { send in
          let isAvailable = await githubIntegration.isAvailable()
          await send(.githubIntegrationAvailabilityUpdated(isAvailable))
        }
        .cancellable(id: CancelID.githubIntegrationAvailability, cancelInFlight: true)

      case .githubIntegrationAvailabilityUpdated(let isAvailable):
        guard state.githubIntegrationAvailability != .disabled else {
          return .none
        }
        state.githubIntegrationAvailability = isAvailable ? .available : .unavailable
        guard isAvailable else {
          for (repositoryID, queued) in state.queuedPullRequestRefreshByRepositoryID {
            state.pendingPullRequestRefreshByRepositoryID.queuePullRequestRefresh(
              repositoryID: repositoryID,
              repositoryRootURL: queued.repositoryRootURL,
              worktreeIDs: queued.worktreeIDs,
            )
          }
          state.queuedPullRequestRefreshByRepositoryID.removeAll()
          state.inFlightPullRequestRefreshRepositoryIDs.removeAll()
          state.inFlightPullRequestBranchSnapshotsByRepositoryID.removeAll()
          let clock = clock
          return .run { send in
            while !Task.isCancelled {
              try await clock.sleep(for: githubIntegrationRecoveryInterval)
              await send(.refreshGithubIntegrationAvailability)
            }
          }
          .cancellable(id: CancelID.githubIntegrationRecovery, cancelInFlight: true)
        }
        let pendingRefreshes = state.pendingPullRequestRefreshByRepositoryID.values.sorted {
          $0.repositoryRootURL.path(percentEncoded: false)
            < $1.repositoryRootURL.path(percentEncoded: false)
        }
        state.pendingPullRequestRefreshByRepositoryID.removeAll()
        return .merge(
          .cancel(id: CancelID.githubIntegrationRecovery),
          .merge(
            pendingRefreshes.map { pending in
              .send(
                .worktreeInfoEvent(
                  .repositoryPullRequestRefresh(
                    repositoryRootURL: pending.repositoryRootURL,
                    worktreeIDs: pending.worktreeIDs
                  )
                )
              )
            }
          )
        )

      case .repositoryPullRequestRefreshCompleted(let repositoryID):
        state.inFlightPullRequestRefreshRepositoryIDs.remove(repositoryID)
        state.inFlightPullRequestBranchSnapshotsByRepositoryID.removeValue(forKey: repositoryID)
        guard state.githubIntegrationAvailability == .available,
          let pending = state.queuedPullRequestRefreshByRepositoryID.removeValue(
            forKey: repositoryID
          )
        else {
          return .none
        }
        return .send(
          .worktreeInfoEvent(
            .repositoryPullRequestRefresh(
              repositoryRootURL: pending.repositoryRootURL,
              worktreeIDs: pending.worktreeIDs
            )
          )
        )

      case .worktreeBranchNameLoaded(let worktreeID, let name):
        state.updateWorktreeName(worktreeID, name: name)
        Self.syncSidebar(&state)
        return .none

      case .worktreeLineChangesLoaded(let worktreeID, let added, let removed):
        return state.updateWorktreeLineChangesEffect(
          worktreeID: worktreeID,
          added: added,
          removed: removed,
        )

      case .repositoryPullRequestsLoaded(let repositoryID, let pullRequestsByWorktreeID):
        guard let repository = state.repositories[id: repositoryID] else {
          return .none
        }
        let branchSnapshot = state.inFlightPullRequestBranchSnapshotsByRepositoryID[repositoryID] ?? [:]
        var archiveWorktreeIDs: [Worktree.ID] = []
        var deleteWorktreeIDs: [Worktree.ID] = []
        var rowEffects: [Effect<Action>] = []
        // Queried-but-missing worktrees must still clear their row watermark.
        let dispatchIDs = Set(branchSnapshot.keys).union(pullRequestsByWorktreeID.keys)
        for worktreeID in dispatchIDs.sorted(by: { $0.rawValue < $1.rawValue }) {
          guard let worktree = repository.worktrees[id: worktreeID] else {
            continue
          }
          let pullRequest = pullRequestsByWorktreeID[worktreeID] ?? nil
          let previousPullRequest = state.sidebarItems[id: worktreeID]?.pullRequest
          let previousMerged = previousPullRequest?.state == "MERGED"
          let nextMerged = pullRequest?.state == "MERGED"
          // Dispatch unconditionally so an identical-PR result still clears the row's watermark.
          rowEffects.append(
            state.updateWorktreePullRequestEffect(
              worktreeID: worktreeID,
              pullRequest: pullRequest,
              branchAtQueryTime: branchSnapshot[worktreeID],
            )
          )
          let mergedLifecycle = state.sidebarItems[id: worktreeID]?.lifecycle ?? .idle
          if let mergedAction = state.mergedWorktreeAction,
            !previousMerged,
            nextMerged,
            !state.isMainWorktree(worktree),
            !state.isWorktreeArchived(worktreeID),
            mergedLifecycle != .deleting,
            mergedLifecycle != .deletingScript
          {
            switch mergedAction {
            case .archive:
              archiveWorktreeIDs.append(worktreeID)
            case .delete:
              deleteWorktreeIDs.append(worktreeID)
            }
          }
        }
        let effects: [Effect<Action>] =
          rowEffects
          + archiveWorktreeIDs.map { .send(.archiveWorktreeConfirmed($0, repositoryID)) }
          + deleteWorktreeIDs.map { .send(.deleteSidebarItemConfirmed($0, repositoryID)) }
        guard !effects.isEmpty else {
          return .none
        }
        return .merge(effects)

      case .pullRequestAction(let worktreeID, let action):
        guard let worktree = state.worktree(for: worktreeID),
          let repositoryID = state.repositoryID(containing: worktreeID),
          let repository = state.repositories[id: repositoryID],
          let pullRequest = state.sidebarItems[id: worktreeID]?.pullRequest
        else {
          return .send(
            .presentAlert(
              title: "Pull request not available",
              message: "Supacode could not find a pull request for this worktree."
            )
          )
        }
        let repoRoot = worktree.repositoryRootURL
        let repoHost = worktree.host
        let worktreeRoot = worktree.workingDirectory
        let pullRequestRefresh = WorktreeInfoWatcherClient.Event.repositoryPullRequestRefresh(
          repositoryRootURL: repoRoot,
          worktreeIDs: repository.worktrees.map(\.id)
        )
        let branchName = pullRequest.headRefName ?? worktree.name
        let failingCheckDetailsURL = (pullRequest.statusCheckRollup?.checks ?? []).first {
          $0.checkState == .failure && $0.detailsUrl != nil
        }?.detailsUrl
        switch action {
        case .openOnGithub:
          guard let url = URL(string: pullRequest.url) else {
            return .send(
              .presentAlert(
                title: "Invalid pull request URL",
                message: "Supacode could not open the pull request URL."
              )
            )
          }
          return .run { @MainActor _ in
            NSWorkspace.shared.open(url)
          }

        case .copyFailingJobURL:
          guard let failingCheckDetailsURL, !failingCheckDetailsURL.isEmpty else {
            return .send(
              .presentAlert(
                title: "Failing check not found",
                message: "Supacode could not find a failing check URL."
              )
            )
          }
          return .run { send in
            await MainActor.run {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(failingCheckDetailsURL, forType: .string)
            }
            await send(.showToast(.success("Failing job URL copied")))
          }

        case .openFailingCheckDetails:
          guard let failingCheckDetailsURL, let url = URL(string: failingCheckDetailsURL) else {
            return .send(
              .presentAlert(
                title: "Failing check not found",
                message: "Supacode could not find a failing check with details."
              )
            )
          }
          return .run { @MainActor _ in
            NSWorkspace.shared.open(url)
          }

        case .markReadyForReview:
          let githubCLI = githubCLI
          let gitClient = gitClient
          let githubIntegration = githubIntegration
          return .run { send in
            guard await githubIntegration.isAvailable() else {
              await send(
                .presentAlert(
                  title: "GitHub integration unavailable",
                  message: "Enable GitHub integration to mark a pull request as ready."
                )
              )
              return
            }
            let remote = await resolveRemoteInfo(
              repositoryRootURL: repoRoot,
              githubCLI: githubCLI,
              gitClient: gitClient
            )
            await send(.showToast(.inProgress("Marking PR ready…")))
            do {
              try await githubCLI.markPullRequestReady(worktreeRoot, remote, pullRequest.number)
              await send(.showToast(.success("Pull request marked ready")))
              await send(.delayedPullRequestRefresh(worktreeID))
            } catch {
              await send(.dismissToast)
              await send(
                .presentAlert(
                  title: "Failed to mark pull request ready",
                  message: error.localizedDescription
                )
              )
            }
          }

        case .merge:
          let githubCLI = githubCLI
          let gitClient = gitClient
          let githubIntegration = githubIntegration
          return .run { send in
            guard await githubIntegration.isAvailable() else {
              await send(
                .presentAlert(
                  title: "GitHub integration unavailable",
                  message: "Enable GitHub integration to merge a pull request."
                )
              )
              return
            }
            @Shared(.repositorySettings(repoRoot, host: repoHost)) var repositorySettings
            @Shared(.settingsFile) var settingsFile
            let strategy =
              repositorySettings.pullRequestMergeStrategy ?? settingsFile.global.pullRequestMergeStrategy
            let remote = await resolveRemoteInfo(
              repositoryRootURL: repoRoot,
              githubCLI: githubCLI,
              gitClient: gitClient
            )
            await send(.showToast(.inProgress("Merging pull request…")))
            do {
              try await githubCLI.mergePullRequest(worktreeRoot, remote, pullRequest.number, strategy)
              await send(.showToast(.success("Pull request merged")))
              await send(.worktreeInfoEvent(pullRequestRefresh))
              await send(.delayedPullRequestRefresh(worktreeID))
            } catch {
              await send(.dismissToast)
              await send(
                .presentAlert(
                  title: "Failed to merge pull request",
                  message: error.localizedDescription
                )
              )
            }
          }

        case .close:
          let githubCLI = githubCLI
          let gitClient = gitClient
          let githubIntegration = githubIntegration
          return .run { send in
            guard await githubIntegration.isAvailable() else {
              await send(
                .presentAlert(
                  title: "GitHub integration unavailable",
                  message: "Enable GitHub integration to close a pull request."
                )
              )
              return
            }
            let remote = await resolveRemoteInfo(
              repositoryRootURL: repoRoot,
              githubCLI: githubCLI,
              gitClient: gitClient
            )
            await send(.showToast(.inProgress("Closing pull request…")))
            do {
              try await githubCLI.closePullRequest(worktreeRoot, remote, pullRequest.number)
              await send(.showToast(.success("Pull request closed")))
              await send(.worktreeInfoEvent(pullRequestRefresh))
              await send(.delayedPullRequestRefresh(worktreeID))
            } catch {
              await send(.dismissToast)
              await send(
                .presentAlert(
                  title: "Failed to close pull request",
                  message: error.localizedDescription
                )
              )
            }
          }

        case .copyCiFailureLogs:
          let githubCLI = githubCLI
          let githubIntegration = githubIntegration
          return .run { send in
            guard await githubIntegration.isAvailable() else {
              await send(
                .presentAlert(
                  title: "GitHub integration unavailable",
                  message: "Enable GitHub integration to copy CI failure logs."
                )
              )
              return
            }
            guard !branchName.isEmpty else {
              await send(
                .presentAlert(
                  title: "Branch name unavailable",
                  message: "Supacode could not determine the pull request branch."
                )
              )
              return
            }
            await send(.showToast(.inProgress("Fetching CI logs…")))
            do {
              guard let run = try await githubCLI.latestRun(worktreeRoot, branchName) else {
                await send(.dismissToast)
                await send(
                  .presentAlert(
                    title: "No workflow runs found",
                    message: "Supacode could not find any workflow runs for this branch."
                  )
                )
                return
              }
              guard run.conclusion?.lowercased() == "failure" else {
                await send(.dismissToast)
                await send(
                  .presentAlert(
                    title: "No failing workflow run",
                    message: "Supacode could not find a failing workflow run to copy logs from."
                  )
                )
                return
              }
              let failedLogs = try await githubCLI.failedRunLogs(worktreeRoot, run.databaseId)
              let logs =
                if failedLogs.isEmpty {
                  try await githubCLI.runLogs(worktreeRoot, run.databaseId)
                } else {
                  failedLogs
                }
              guard !logs.isEmpty else {
                await send(.dismissToast)
                await send(
                  .presentAlert(
                    title: "No CI logs available",
                    message: "The workflow run failed but produced no logs."
                  )
                )
                return
              }
              await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(logs, forType: .string)
              }
              await send(.showToast(.success("CI failure logs copied")))
            } catch {
              await send(.dismissToast)
              await send(
                .presentAlert(
                  title: "Failed to copy CI failure logs",
                  message: error.localizedDescription
                )
              )
            }
          }

        case .rerunFailedJobs:
          let githubCLI = githubCLI
          let githubIntegration = githubIntegration
          return .run { send in
            guard await githubIntegration.isAvailable() else {
              await send(
                .presentAlert(
                  title: "GitHub integration unavailable",
                  message: "Enable GitHub integration to re-run failed jobs."
                )
              )
              return
            }
            guard !branchName.isEmpty else {
              await send(
                .presentAlert(
                  title: "Branch name unavailable",
                  message: "Supacode could not determine the pull request branch."
                )
              )
              return
            }
            await send(.showToast(.inProgress("Re-running failed jobs…")))
            do {
              guard let run = try await githubCLI.latestRun(worktreeRoot, branchName) else {
                await send(.dismissToast)
                await send(
                  .presentAlert(
                    title: "No workflow runs found",
                    message: "Supacode could not find any workflow runs for this branch."
                  )
                )
                return
              }
              guard run.conclusion?.lowercased() == "failure" else {
                await send(.dismissToast)
                await send(
                  .presentAlert(
                    title: "No failing workflow run",
                    message: "Supacode could not find a failing workflow run to re-run."
                  )
                )
                return
              }
              try await githubCLI.rerunFailedJobs(worktreeRoot, run.databaseId)
              await send(.showToast(.success("Failed jobs re-run started")))
              await send(.delayedPullRequestRefresh(worktreeID))
            } catch {
              await send(.dismissToast)
              await send(
                .presentAlert(
                  title: "Failed to re-run failed jobs",
                  message: error.localizedDescription
                )
              )
            }
          }
        }

      case .setGithubIntegrationEnabled(let isEnabled):
        if isEnabled {
          state.githubIntegrationAvailability = .unknown
          state.pendingPullRequestRefreshByRepositoryID.removeAll()
          state.queuedPullRequestRefreshByRepositoryID.removeAll()
          state.inFlightPullRequestRefreshRepositoryIDs.removeAll()
          state.inFlightPullRequestBranchSnapshotsByRepositoryID.removeAll()
          return .merge(
            .cancel(id: CancelID.githubIntegrationRecovery),
            .send(.refreshGithubIntegrationAvailability)
          )
        }
        state.githubIntegrationAvailability = .disabled
        state.pendingPullRequestRefreshByRepositoryID.removeAll()
        state.queuedPullRequestRefreshByRepositoryID.removeAll()
        state.inFlightPullRequestRefreshRepositoryIDs.removeAll()
        state.inFlightPullRequestBranchSnapshotsByRepositoryID.removeAll()
        let worktreeIDs = state.sidebarItems.compactMap { $0.pullRequest != nil ? $0.id : nil }
        var clearEffects: [Effect<Action>] = []
        for worktreeID in worktreeIDs {
          clearEffects.append(
            state.updateWorktreePullRequestEffect(
              worktreeID: worktreeID,
              pullRequest: nil,
            )
          )
        }
        return .merge(
          clearEffects + [
            .cancel(id: CancelID.githubIntegrationAvailability),
            .cancel(id: CancelID.githubIntegrationRecovery),
          ]
        )

      case .setMergedWorktreeAction(let action):
        state.mergedWorktreeAction = action
        return .none

      case .setAutoDeleteArchivedWorktreesAfterDays(let days):
        state.autoDeleteArchivedWorktreesAfterDays = days
        guard days != nil else { return .none }
        return .send(.autoDeleteExpiredArchivedWorktrees)

      case .autoDeleteExpiredArchivedWorktrees:
        guard let period = state.autoDeleteArchivedWorktreesAfterDays else { return .none }
        let cutoff = now.addingTimeInterval(-Double(period.rawValue) * secondsPerDay)
        var targets: [(Worktree.ID, Repository.ID)] = []
        // Folder-synthetic archived entries can't be produced by
        // any current user path (context-menu / shortcut / deeplink
        // all reject folder archives). If one leaks into persisted
        // state: a bug in a future archive path, a migration
        // regression, or hand-edited sidebar.json, so we both flag
        // the invariant breach AND purge the stray entry from
        // `sidebar.archivedWorktrees`, so the next reload doesn't
        // re-fire `reportIssue` forever.
        var strayFolderArchives: [(Worktree.ID, Repository.ID)] = []
        for archived in state.sidebar.archivedWorktrees
        where state.repositories[id: archived.repositoryID]?.kind == .folder {
          strayFolderArchives.append((archived.worktreeID, archived.repositoryID))
        }
        if !strayFolderArchives.isEmpty {
          for (worktreeID, _) in strayFolderArchives {
            reportIssue(
              """
              Auto-delete encountered folder-synthetic archived worktree \(worktreeID): \
              folders are not archivable. Purging the stray entry.
              """
            )
          }
          state.$sidebar.withLock { sidebar in
            for (worktreeID, repositoryID) in strayFolderArchives {
              sidebar.remove(worktree: worktreeID, in: repositoryID, from: .archived)
            }
          }
        }
        for archived in state.sidebar.archivedWorktrees {
          let worktreeID = archived.worktreeID
          guard archived.archivedAt <= cutoff else { continue }
          if state.repositories[id: archived.repositoryID]?.kind == .folder {
            // Already purged above, defensive skip.
            continue
          }
          let autoDeleteLifecycle = state.sidebarItems[id: worktreeID]?.lifecycle ?? .idle
          guard autoDeleteLifecycle == .idle else { continue }
          guard let repository = state.repositories.first(where: { $0.worktrees[id: worktreeID] != nil }),
            let worktree = repository.worktrees[id: worktreeID]
          else {
            repositoriesLogger.debug(
              "Auto-delete skipping expired worktree \(worktreeID): not found in loaded repositories."
            )
            continue
          }
          guard !state.isMainWorktree(worktree) else {
            repositoriesLogger.debug(
              "Auto-delete skipping expired worktree \(worktreeID): main worktree cannot be deleted."
            )
            continue
          }
          targets.append((worktreeID, repository.id))
        }
        guard !targets.isEmpty else { return .none }
        repositoriesLogger.info("Auto-deleting \(targets.count) expired archived worktree(s).")
        return .merge(
          targets.map { worktreeID, repositoryID in
            .send(.deleteSidebarItemConfirmed(worktreeID, repositoryID))
          }
        )

      case .setMoveNotifiedWorktreeToTop(let isEnabled):
        state.moveNotifiedWorktreeToTop = isEnabled
        return .none

      case .setInstalledOpenActions(let installed):
        guard state.installedOpenActions != installed else { return .none }
        state.installedOpenActions = installed
        return .none

      case .openActionSettingsChanged:
        // The post-reduce hook arms the resolution effect from the invalidation bits.
        return .none

      case .resolveOpenActions:
        state.seedUnresolvedOpenActions()
        return Self.resolveOpenActionsEffect(state: state)

      case .openActionsResolved(let resolved):
        // A repository can leave the roster while the pass is in flight, and the
        // post-reduce prune has already run by the time this lands. Merging its entry
        // back would resurrect a key nothing prunes again.
        let updates = resolved.filter {
          state.repositories[id: $0.key] != nil && state.openActionByRepositoryID[$0.key] != $0.value
        }
        guard !updates.isEmpty else { return .none }
        state.openActionByRepositoryID.merge(updates) { _, resolved in resolved }
        return .none
      default:
        return .none
      }
    }
  }

  /// Rebuilds the open-action map off the main actor. Every entry it resolves reads
  /// that repository's `supacode.json`, so this must stay an effect: the synchronous
  /// read on the reducer is what hung the sidebar's context menu.
  ///
  /// Re-reads every repository, every pass. Nothing watches `supacode.json`
  /// (`RepositorySettingsKey.subscribe` is a no-op), so an entry resolved once would never
  /// be revisited, and an agent or a `git pull` inside a Supacode terminal rewrites that
  /// file with no activation to catch it. An unchanged result writes nothing.
  static func resolveOpenActionsEffect(state: State) -> Effect<Action> {
    // `.none` carries no cancellation id, so an empty pass can't cancel a live one.
    guard !state.repositories.isEmpty else { return .none }
    let inputs = state.repositories.map(OpenActionResolutionInput.init)
    let installed = state.installedOpenActions
    return .run { send in
      // The `.openActionsResolved` arm drops what didn't change. Diffing here too
      // would only compare against a creation-time snapshot, which is exactly the
      // stale view that must not decide anything.
      await send(.openActionsResolved(OpenActionResolver.resolve(inputs: inputs, installed: installed)))
    }
    // One cancellation id, so only ever one pass in flight: two overlapping passes
    // could otherwise land out of order and merge an older snapshot over a newer one.
    .cancellable(id: CancelID.resolveOpenActions, cancelInFlight: true)
  }

  /// Pin / unpin / toast / notification / worktree-info-event handlers, split from `body` to keep
  /// its `Reduce` closure under the type-checker's complexity limit.
  var worktreeNotificationReducer: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .pinWorktree(let worktreeID):
        // Git main worktrees render in the main slot, never the pinned list, so pinning is a no-op.
        // Scope the skip to git repos: folder synthetics are `isMainWorktree` by geometry but ARE pinnable.
        guard let worktree = state.worktree(for: worktreeID),
          let repositoryID = state.repositoryID(containing: worktreeID),
          let repository = state.repositories[id: repositoryID]
        else {
          return .none
        }
        if repository.isGitRepository, state.isMainWorktree(worktree) {
          return .none
        }
        // Pin / unpin are unarchive-adjacent (the new bucket flow drops
        // `archivedAt` via `removeAnywhere` + `insert`). Refuse to pin
        // an archived row so a deeplink or programmatic dispatch can't
        // silently resurrect it; the user must unarchive first.
        if state.isWorktreeArchived(worktreeID) { return .none }
        analyticsClient.capture("worktree_pinned", nil)
        state.$sidebar.withLock { sidebar in
          // `removeAnywhere` + `insert` enforces the "exactly one bucket"
          // invariant against pre-states that have the row in `.pinned` and
          // `.unpinned` simultaneously (hand-edit, migrator race) and also
          // handles the not-bucketed case (folders before first reconcile).
          // The carried Item preserves user-set `title` / `color` across
          // the bucket move. Prefer the logical source (`.unpinned`) so a
          // corrupted double-bucket pre-state surfaces the live unpinned
          // row's payload, not a stale `.pinned` sibling.
          var carried =
            sidebar.removeAnywhere(
              worktree: worktreeID,
              in: repositoryID,
              preferring: [.unpinned, .pinned, .archived]
            ) ?? .init()
          carried.archivedAt = nil
          sidebar.insert(
            worktree: worktreeID,
            in: repositoryID,
            bucket: .pinned,
            item: carried,
            position: 0
          )
        }
        RepositoriesFeature.syncSidebar(&state)
        return .none

      case .unpinWorktree(let worktreeID):
        guard let repositoryID = state.repositoryID(containing: worktreeID),
          state.repositories[id: repositoryID] != nil
        else {
          return .none
        }
        // Mirrors the `pinWorktree` archive guard: don't let an archived
        // row trip through the bucket machinery and lose its `archivedAt`
        // timestamp as a side effect.
        if state.isWorktreeArchived(worktreeID) { return .none }
        analyticsClient.capture("worktree_unpinned", nil)
        state.$sidebar.withLock { sidebar in
          // Same invariant as `pinWorktree`: collapse any pre-existing
          // bucket placement into a single `.unpinned` entry, carrying
          // the Item forward so `title` / `color` survive unpin. Prefer
          // `.pinned` so a corrupted double-bucket pre-state surfaces
          // the live pinned row's payload over a stale unpinned sibling.
          var carried =
            sidebar.removeAnywhere(
              worktree: worktreeID,
              in: repositoryID,
              preferring: [.pinned, .unpinned, .archived]
            ) ?? .init()
          carried.archivedAt = nil
          sidebar.insert(
            worktree: worktreeID,
            in: repositoryID,
            bucket: .unpinned,
            item: carried,
            position: 0
          )
        }
        RepositoriesFeature.syncSidebar(&state)
        return .none

      case .presentAlert(let title, let message):
        state.alert = messageAlert(title: title, message: message)
        return .none

      case .showToast(let toast):
        state.statusToast = toast
        switch toast {
        case .inProgress:
          return .cancel(id: CancelID.toastAutoDismiss)
        case .success:
          let clock = clock
          return .run { send in
            try await clock.sleep(for: toastAutoDismissDelay)
            await send(.dismissToast)
          }
          .cancellable(id: CancelID.toastAutoDismiss, cancelInFlight: true)
        }

      case .dismissToast:
        state.statusToast = nil
        return .none

      case .toggleInspectorPane(let target):
        if state.inspectorPresented, state.inspectorPane == target {
          state.inspectorPresented = false
        } else {
          state.inspectorPane = target
          state.inspectorPresented = true
        }
        return .none

      case .setInspectorPresented(let presented):
        state.inspectorPresented = presented
        return .none

      case .delayedPullRequestRefresh(let worktreeID):
        guard let worktree = state.worktree(for: worktreeID),
          let repositoryID = state.repositoryID(containing: worktreeID),
          let repository = state.repositories[id: repositoryID]
        else {
          return .none
        }
        let repositoryRootURL = worktree.repositoryRootURL
        let worktreeIDs = repository.worktrees.map(\.id)
        let clock = clock
        return .run { send in
          try await clock.sleep(for: delayedPullRequestRefreshDelay)
          await send(
            .worktreeInfoEvent(
              .repositoryPullRequestRefresh(
                repositoryRootURL: repositoryRootURL,
                worktreeIDs: worktreeIDs
              )
            )
          )
        }
        .cancellable(id: CancelID.delayedPRRefresh(worktreeID), cancelInFlight: true)

      case .worktreeInfoEvent(let event):
        switch event {
        case .branchChanged(let worktreeID):
          guard let worktree = state.worktree(for: worktreeID) else {
            return .none
          }
          let worktreeURL = worktree.workingDirectory
          let gitClient = gitClient(for: worktree)
          return .run { send in
            if let name = await gitClient.branchName(worktreeURL) {
              await send(.worktreeBranchNameLoaded(worktreeID: worktreeID, name: name))
            }
          }
        case .filesChanged(let worktreeID):
          guard let worktree = state.worktree(for: worktreeID) else {
            return .none
          }
          let worktreeURL = worktree.workingDirectory
          let gitClient = gitClient(for: worktree)
          return .run { send in
            if let changes = await gitClient.lineChanges(worktreeURL) {
              await send(
                .worktreeLineChangesLoaded(
                  worktreeID: worktreeID,
                  added: changes.added,
                  removed: changes.removed
                )
              )
            }
          }
        case .repositoryPullRequestRefresh(let repositoryRootURL, let worktreeIDs):
          let worktrees = worktreeIDs.compactMap { state.worktree(for: $0) }
          guard let firstWorktree = worktrees.first,
            let repositoryID = state.repositoryID(containing: firstWorktree.id)
          else {
            return .none
          }
          // PR refresh runs `gh` against the local repo; a remote-only repo has
          // no local checkout to serve it. Skip (gh-over-ssh is out of scope).
          guard state.repositories[id: repositoryID]?.host == nil else {
            return .none
          }
          var seen = Set<String>()
          let branches =
            worktrees
            .map(\.name)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
          guard !branches.isEmpty else {
            return .none
          }
          switch state.githubIntegrationAvailability {
          case .available:
            if state.inFlightPullRequestRefreshRepositoryIDs.contains(repositoryID) {
              state.queuedPullRequestRefreshByRepositoryID.queuePullRequestRefresh(
                repositoryID: repositoryID,
                repositoryRootURL: repositoryRootURL,
                worktreeIDs: worktreeIDs,
              )
              return .none
            }
            state.inFlightPullRequestRefreshRepositoryIDs.insert(repositoryID)
            // Snapshot the row's `branchName` (canonical for the watermark)
            // before the network kicks off so late results for a renamed
            // branch drop in the row reducer.
            var branchSnapshot: [Worktree.ID: String] = [:]
            var armEffects: [Effect<Action>] = []
            for worktree in worktrees {
              guard let row = state.sidebarItems[id: worktree.id] else { continue }
              branchSnapshot[worktree.id] = row.branchName
              armEffects.append(
                .send(
                  .sidebarItems(
                    .element(id: worktree.id, action: .pullRequestQueryStarted(branch: row.branchName))
                  )
                )
              )
            }
            state.inFlightPullRequestBranchSnapshotsByRepositoryID[repositoryID] = branchSnapshot
            return .merge(
              .merge(armEffects),
              refreshRepositoryPullRequests(
                repositoryID: repositoryID,
                repositoryRootURL: repositoryRootURL,
                worktrees: worktrees,
                branches: branches
              )
            )
          case .unknown:
            state.pendingPullRequestRefreshByRepositoryID.queuePullRequestRefresh(
              repositoryID: repositoryID,
              repositoryRootURL: repositoryRootURL,
              worktreeIDs: worktreeIDs,
            )
            return .send(.refreshGithubIntegrationAvailability)
          case .checking:
            state.pendingPullRequestRefreshByRepositoryID.queuePullRequestRefresh(
              repositoryID: repositoryID,
              repositoryRootURL: repositoryRootURL,
              worktreeIDs: worktreeIDs,
            )
            return .none
          case .unavailable:
            state.pendingPullRequestRefreshByRepositoryID.queuePullRequestRefresh(
              repositoryID: repositoryID,
              repositoryRootURL: repositoryRootURL,
              worktreeIDs: worktreeIDs,
            )
            return .none
          case .disabled:
            return .none
          }
        }
      default:
        return .none
      }
    }
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .task:
        // `sidebar` is already hydrated from `sidebar.json` (loaded
        // synchronously by the SharedKey when State is constructed),
        // so `.task` has no persistence fan-out left, it just flags
        // the focus restore and kicks off the repository load.
        state.shouldRestoreLastFocusedWorktree = state.sidebar.focusedWorktreeID != nil
        return .send(.loadPersistedRepositories)

      case .sidebarGroupingTogglesChanged:
        // The post-reduce hook below picks up the toggle state and rebuilds.
        // Auto-dismiss the highlight onboarding card when both toggles end up
        // off; the `SidebarCommands` menu setters fire the same dismiss so
        // toggling while the sidebar column is collapsed is also covered.
        @Shared(.sidebarGroupPinnedRows) var groupPinned
        @Shared(.sidebarGroupActiveRows) var groupActive
        if !groupPinned, !groupActive {
          @Shared(.appStorage("highlightRelevantOnboardingDismissedAt"))
          var dismissedAt: Date = .distantPast
          if !HighlightRelevantOnboardingCardView.isDismissed(at: dismissedAt) {
            $dismissedAt.withLock { $0 = now }
          }
        }
        return .none

      case .sidebarNestByBranchChanged:
        // No-op handler: the post-reduce hook reads `sidebarNestWorktreesByBranch`
        // and rebuilds `sidebarStructure` so the alphabetical per-bucket sort
        // lands in `slotByID` / `hotkeySlots`.
        return .none

      case .setOpenPanelPresented(let isPresented):
        state.isOpenPanelPresented = isPresented
        return .none

      case .requestAddRemoteRepository, .requestEditRemoteRepository, .remoteConnectionForm:
        // Handled by `remoteConnectionFormReducer` so the form's child reducer
        // runs before the delegate handler nils the presented state.
        return .none

      case .requestCloneRepository, .cloneRepositoryForm:
        // Handled by `cloneRepositoryFormReducer` so the form's child reducer
        // runs before the delegate handler nils the presented state.
        return .none

      case .removeRemoteRepository(let repositoryID):
        @Shared(.remoteRepositoryRoots) var remoteRepositoryRoots
        $remoteRepositoryRoots.withLock { roots in
          roots.removeAll { $0 == repositoryID.rawValue }
        }
        // Drop persisted customization so re-adding the same host/path doesn't
        // silently restore the old title/color, matching the other removal paths.
        state.$sidebar.withLock { _ = $0.sections.removeValue(forKey: repositoryID) }
        return .send(.loadPersistedRepositories)

      case .loadPersistedRepositories:
        state.alert = nil
        state.isRefreshingWorktrees = false
        return .run { send in
          let loadedPaths = await repositoryPersistence.loadRoots()
          let rootPaths = RepositoryPathNormalizer.normalize(loadedPaths)
          let roots = rootPaths.map { URL(fileURLWithPath: $0) }
          let loadResult = await loadRepositoriesData(roots)
          await send(.gitEnvironmentChanged(loadResult.environmentError))
          await send(
            .repositoriesLoaded(
              loadResult.repositories,
              failures: loadResult.failures,
              roots: roots,
              animated: false
            )
          )
        }
        .cancellable(id: CancelID.load, cancelInFlight: true)

      case .refreshWorktrees:
        state.isRefreshingWorktrees = true
        return .send(.reloadRepositories(animated: false))

      case .reloadRepositories(let animated):
        // Deliberately NOT clearing `state.alert` here,
        // `.reloadRepositories` is a data-layer refresh and fires
        // from both user intents (refresh hotkey) and downstream of
        // delete/archive flows. Wiping a just-set terminal alert
        // (e.g. the consolidated trash-failure alert the aggregator
        // set before firing `.repositoriesRemoved` → `.repositoriesLoaded`
        // → `.autoDeleteExpiredArchivedWorktrees`) was the source
        // of an observable "failure alert vanishes on the same
        // tick" bug. Confirmation-style alerts are already cleared
        // by their own confirm handlers upstream of this action.
        let roots = state.repositoryRoots
        // A remote-only setup has no local roots, but the load path still
        // appends persisted remote configs, so a refresh must run for it.
        // Also keep refreshing while environment-blocked (even with zero roots)
        // so accepting the Xcode license re-probes and clears the banner without
        // a relaunch.
        guard
          !roots.isEmpty || !Self.persistedRemoteRepositoryRoots().isEmpty
            || state.gitEnvironmentError != nil
        else {
          state.isRefreshingWorktrees = false
          return .none
        }
        return loadRepositories(roots, animated: animated)

      case .gitEnvironmentChanged(let environmentError):
        // Guard so the periodic refresh doesn't re-publish an unchanged value.
        guard state.gitEnvironmentError != environmentError else { return .none }
        state.gitEnvironmentError = environmentError
        return .none

      case .repositoriesLoaded(let repositories, let failures, let roots, let animated):
        state.isRefreshingWorktrees = false
        let previousSelection = state.selectedWorktreeID
        let previousSelectedWorktree = state.worktree(for: previousSelection)
        let mergedRemote = Self.mergePersistedRemoteRepositories(into: repositories, existingState: state)
        let mergedRepositories = mergedRemote.repositories
        let incomingRepositories = IdentifiedArray(uniqueElements: mergedRepositories)
        let repositoriesChanged = incomingRepositories != state.repositories
        _ = applyRepositories(
          mergedRepositories,
          roots: roots,
          // Don't prune archived worktree ids while remotes are still resolving
          // (their worktrees aren't in the roster yet) or while git is
          // environment-blocked (the suppressed repos' worktrees are absent, so
          // pruning would drop their curation for a transient failure).
          shouldPruneArchivedWorktreeIDs: failures.isEmpty && mergedRemote.resolvingIDs.isEmpty
            && state.gitEnvironmentError == nil,
          state: &state,
          animated: animated
        )
        state.repositoryRoots = roots
        state.isInitialLoadComplete = true
        state.resolvingRemoteRepositoryIDs = mergedRemote.resolvingIDs
        // Local failures only; remote failures arrive via `.remoteRepositoryResolved`.
        state.loadFailuresByID = Dictionary(
          uniqueKeysWithValues: failures.map { ($0.rootID, $0.message) }
        )
        state.dropStaleFailedRepositorySelection()
        let selectedWorktree = state.worktree(for: state.selectedWorktreeID)
        let selectionChanged = state.hasSelectionChanged(
          previousSelectionID: previousSelection,
          previousSelectedWorktree: previousSelectedWorktree,
          selectedWorktreeID: state.selectedWorktreeID,
          selectedWorktree: selectedWorktree,
        )
        var allEffects: [Effect<Action>] = []
        if repositoriesChanged {
          allEffects.append(.send(.delegate(.repositoriesChanged(state.repositories))))
        }
        if selectionChanged {
          allEffects.append(.send(.delegate(.selectedWorktreeChanged(selectedWorktree))))
        }
        // The sidebar reconciler (`reconcileSidebarState`) already
        // flushed any sidebar mutations through `$sidebar.withLock`,
        // so no per-slice save effects are needed here, the SharedKey
        // writes `sidebar.json` atomically.
        if state.autoDeleteArchivedWorktreesAfterDays != nil {
          allEffects.append(.send(.autoDeleteExpiredArchivedWorktrees))
        }
        // Re-probe remotes on every reload so refreshes re-list them.
        if mergedRemote.repositories.contains(where: { $0.host != nil }) {
          allEffects.append(.send(.resolveRemoteRepositories))
        }
        return .merge(allEffects)

      case .resolveRemoteRepositories:
        let roots = Self.persistedRemoteRepositoryRoots()
        guard !roots.isEmpty else { return .none }
        return .run { send in
          // Resolve concurrently so one slow host doesn't gate the others; each
          // streams its own result. The background-probe ssh profile bounds a
          // dead host, so a stuck connection never spins forever.
          await withTaskGroup(of: Void.self) { group in
            var seen: Set<Repository.ID> = []
            for root in roots {
              guard let (host, remotePath) = Self.parseRemoteRoot(root) else {
                repositoriesLogger.warning("Skipping unparseable persisted remote id: \(root).")
                continue
              }
              let repoID = Self.remoteRepositoryID(host: host, remotePath: remotePath)
              guard seen.insert(repoID).inserted else { continue }
              group.addTask {
                let loaded = await Self.loadRemoteRepository(host: host, remotePath: remotePath, repoID: repoID)
                await send(
                  .remoteRepositoryResolved(
                    repositoryID: repoID,
                    repository: loaded.repository,
                    failureMessage: loaded.failure?.message
                  )
                )
              }
            }
          }
        }
        .cancellable(id: CancelID.resolveRemoteRepositories, cancelInFlight: true)

      case .remoteRepositoryResolved(let repositoryID, let repository, let failureMessage):
        let wasResolving = state.resolvingRemoteRepositoryIDs.remove(repositoryID) != nil
        // Drop a result whose config was removed or re-keyed mid-probe.
        guard let existing = state.repositories[id: repositoryID] else { return .none }
        // A superseded probe must not downgrade a resolved remote to a placeholder.
        if !wasResolving, repository.worktrees.isEmpty, !existing.worktrees.isEmpty {
          repositoriesLogger.debug("Ignoring stale remote resolution for \(repositoryID).")
          return .none
        }
        if let failureMessage {
          state.loadFailuresByID[repositoryID] = failureMessage
        } else {
          state.loadFailuresByID[repositoryID] = nil
        }
        let didChange = existing != repository
        state.repositories[id: repositoryID] = repository
        // Reconcile the updated repo's worktrees into the sidebar (seeds buckets
        // / items) exactly as a bulk load would.
        _ = applyRepositories(
          Array(state.repositories),
          roots: state.repositoryRoots,
          shouldPruneArchivedWorktreeIDs: false,
          state: &state,
          animated: true
        )
        // Clear a selected "can't reach" row once the remote resolves.
        state.dropStaleFailedRepositorySelection()
        // A placeholder to resolved transition changes the worktree roster, so
        // tell downstream consumers (terminal prune, settings summaries); without
        // this a restored remote surface stays pruned until the next full reload.
        return didChange ? .send(.delegate(.repositoriesChanged(state.repositories))) : .none

      case .openRepositories(let urls):
        analyticsClient.capture("repository_added", ["count": urls.count])
        state.alert = nil
        return .run { send in
          let loadedPaths = await repositoryPersistence.loadRoots()
          let existingRootPaths = RepositoryPathNormalizer.normalize(loadedPaths)
          var resolvedRoots: [URL] = []
          var invalidRoots: [String] = []
          for url in urls {
            do {
              let root = try await gitClient.repoRoot(url)
              resolvedRoots.append(root)
            } catch {
              // `repoRoot` failed. A readable directory is still worth keeping: a
              // plain folder repo, or a real git repo we can't resolve because git
              // is environment-blocked. Either way persist it and let the load
              // classify it (folder, blocked warning row, or a real failure once
              // git returns). A non-directory is genuinely invalid.
              let standardized = url.standardizedFileURL
              var isDirectory: ObjCBool = false
              let exists = FileManager.default.fileExists(
                atPath: standardized.path(percentEncoded: false),
                isDirectory: &isDirectory
              )
              if exists, isDirectory.boolValue {
                resolvedRoots.append(standardized)
              } else {
                invalidRoots.append(url.path(percentEncoded: false))
              }
            }
          }
          let resolvedRootPaths = RepositoryPathNormalizer.normalize(
            resolvedRoots.map { $0.path(percentEncoded: false) }
          )
          let mergedPaths = RepositoryPathNormalizer.normalize(existingRootPaths + resolvedRootPaths)
          let mergedRoots = mergedPaths.map { URL(fileURLWithPath: $0) }
          await repositoryPersistence.saveRoots(mergedPaths)
          let loadResult = await loadRepositoriesData(mergedRoots)
          await send(.gitEnvironmentChanged(loadResult.environmentError))
          await send(
            .openRepositoriesFinished(
              loadResult.repositories,
              failures: loadResult.failures,
              invalidRoots: invalidRoots,
              roots: mergedRoots
            )
          )
        }
        .cancellable(id: CancelID.load, cancelInFlight: true)

      case .openRepositoriesFinished(let repositories, let failures, let invalidRoots, let roots):
        state.isRefreshingWorktrees = false
        let previousSelection = state.selectedWorktreeID
        let previousSelectedWorktree = state.worktree(for: previousSelection)
        let mergedRemote = Self.mergePersistedRemoteRepositories(into: repositories, existingState: state)
        _ = applyRepositories(
          mergedRemote.repositories,
          roots: roots,
          // Keep archived curation while git is environment-blocked: the
          // suppressed repos' worktrees are absent from the roster.
          shouldPruneArchivedWorktreeIDs: failures.isEmpty && mergedRemote.resolvingIDs.isEmpty
            && state.gitEnvironmentError == nil,
          state: &state,
          animated: false
        )
        state.repositoryRoots = roots
        state.isInitialLoadComplete = true
        state.resolvingRemoteRepositoryIDs = mergedRemote.resolvingIDs
        state.loadFailuresByID = Dictionary(
          uniqueKeysWithValues: failures.map { ($0.rootID, $0.message) }
        )
        state.dropStaleFailedRepositorySelection()
        if !invalidRoots.isEmpty {
          let message = invalidRoots.map { "Supacode couldn't read \($0)." }.joined(separator: "\n")
          state.alert = messageAlert(
            title: "Some items couldn't be opened",
            message: message
          )
        }
        let selectedWorktree = state.worktree(for: state.selectedWorktreeID)
        let selectionChanged = state.hasSelectionChanged(
          previousSelectionID: previousSelection,
          previousSelectedWorktree: previousSelectedWorktree,
          selectedWorktreeID: state.selectedWorktreeID,
          selectedWorktree: selectedWorktree,
        )
        var allEffects: [Effect<Action>] = [
          .send(.delegate(.repositoriesChanged(state.repositories)))
        ]
        if selectionChanged {
          allEffects.append(.send(.delegate(.selectedWorktreeChanged(selectedWorktree))))
        }
        // See `.repositoriesLoaded` above for why no per-slice save
        // effects run here; sidebar mutations already flushed.
        if state.autoDeleteArchivedWorktreesAfterDays != nil {
          allEffects.append(.send(.autoDeleteExpiredArchivedWorktrees))
        }
        // Adding a local repo resolves only new placeholders; reload refreshes resolved remotes.
        if !mergedRemote.resolvingIDs.isEmpty {
          allEffects.append(.send(.resolveRemoteRepositories))
        }
        return .merge(allEffects)

      case .selectionChanged(let selections, let focusTerminal):
        return state.reduceSelectionChangedEffect(
          selections: selections,
          focusTerminal: focusTerminal,
        )

      case .repositoryExpansionChanged(let repositoryID, let isExpanded):
        state.$sidebar.withLock { sidebar in
          // Writing the explicit bit (true / false) instead of
          // adding/removing from a set lets future default-flip
          // logic distinguish "user expanded" from "never touched".
          sidebar.sections[repositoryID, default: .init()].collapsed = !isExpanded
        }
        return .none

      case .branchNestExpansionChanged(let repositoryID, let bucketID, let prefix, let isExpanded):
        // Only `.pinned` / `.unpinned` render nested rows; `.archived` has no
        // chevron and would just bloat `sidebar.json` with dead entries. Also
        // refuse to materialize a phantom section for an unknown repo: the
        // chevron is unreachable without an existing section, so anything
        // hitting this path with a missing repository is stale UI / deeplink
        // noise rather than a legitimate intent.
        guard bucketID != .archived, state.sidebar.sections[repositoryID] != nil else { return .none }
        state.$sidebar.withLock { sidebar in
          guard var section = sidebar.sections[repositoryID] else { return }
          var bucket = section.buckets[bucketID] ?? .init()
          if isExpanded {
            bucket.collapsedBranchPrefixes.remove(prefix)
          } else {
            bucket.collapsedBranchPrefixes.insert(prefix)
          }
          section.buckets[bucketID] = bucket
          sidebar.sections[repositoryID] = section
        }
        return .none

      case .setAllSidebarGroupsExpanded(let isExpanded):
        // Iterate the full roster, not just `sidebar.sections.keys`: the section
        // map is sparse (a repo renders expanded until something writes an
        // entry), so collapsing must materialize one for every repo.
        let repositoryIDs = state.repositories.map(\.id)
        state.$sidebar.withLock { sidebar in
          for repositoryID in repositoryIDs {
            guard isExpanded else {
              // Collapse keeps branch-group prefixes so each group's layout
              // survives when its section reopens.
              sidebar.sections[repositoryID, default: .init()].collapsed = true
              continue
            }
            // A repo with no entry is already fully open, so nothing to undo.
            guard var section = sidebar.sections[repositoryID] else { continue }
            section.collapsed = false
            for bucketID in Array(section.buckets.keys) {
              section.buckets[bucketID]?.collapsedBranchPrefixes.removeAll()
            }
            sidebar.sections[repositoryID] = section
          }
        }
        return .none

      case .selectArchivedWorktrees:
        state.selection = .archivedWorktrees
        state.sidebarSelectedWorktreeIDs = []
        return .send(.delegate(.selectedWorktreeChanged(nil)))

      case .setSidebarSelectedWorktreeIDs(let worktreeIDs):
        let validWorktreeIDs = state.selectableWorktreeIDs
        var nextWorktreeIDs = worktreeIDs.intersection(validWorktreeIDs)
        if let selectedWorktreeID = state.selectedWorktreeID, validWorktreeIDs.contains(selectedWorktreeID) {
          nextWorktreeIDs.insert(selectedWorktreeID)
        }
        state.sidebarSelectedWorktreeIDs = nextWorktreeIDs
        return .none

      case .selectWorktree(let worktreeID, let focusTerminal):
        state.setSingleWorktreeSelection(worktreeID)
        let selectedWorktree = state.worktree(for: worktreeID)
        var effects: [Effect<Action>] = [
          .send(.delegate(.selectedWorktreeChanged(selectedWorktree)))
        ]
        if focusTerminal, let worktreeID, state.sidebarItems[id: worktreeID] != nil {
          effects.append(
            .send(.sidebarItems(.element(id: worktreeID, action: .focusTerminalRequested)))
          )
        }
        return .merge(effects)

      case .selectWorktreeAtHotkeySlot(let index):
        // Snapshot-driven menu items capture only the slot index, so the
        // current `hotkeySlots` lookup happens here at action time. Out-of-range
        // slots beep so the user gets feedback that the shortcut hit nothing.
        let slots = state.sidebarStructure.hotkeySlots
        guard slots.indices.contains(index) else {
          return .run { _ in NSSound.beep() }
        }
        return .send(.selectWorktree(slots[index].id, focusTerminal: true))

      case .selectNextWorktree:
        guard let id = state.worktreeID(byOffset: 1) else {
          return .run { _ in NSSound.beep() }
        }
        return .send(.selectWorktree(id, focusTerminal: true))

      case .selectPreviousWorktree:
        guard let id = state.worktreeID(byOffset: -1) else {
          return .run { _ in NSSound.beep() }
        }
        return .send(.selectWorktree(id, focusTerminal: true))

      case .worktreeHistoryBack:
        return state.navigateWorktreeHistoryEffect(direction: .back)

      case .worktreeHistoryForward:
        return state.navigateWorktreeHistoryEffect(direction: .forward)

      case .revealSelectedWorktreeInSidebar:
        guard let worktreeID = state.selectedWorktreeID,
          let repositoryID = state.repositoryID(containing: worktreeID)
        else { return .none }
        // Resolve outside the lock to keep the critical section short.
        let branchName = state.sidebarItems[id: worktreeID]?.branchName
        let containingBucket = state.sidebar.currentBucket(of: worktreeID, in: repositoryID)
        state.$sidebar.withLock { sidebar in
          sidebar.sections[repositoryID, default: .init()].collapsed = false
          // Uncollapse any ancestor branch prefix so a reveal / deeplink to
          // `feature/tools/api` doesn't leave the row hidden inside a
          // collapsed `feature/tools` group header.
          guard let branchName, let bucketID = containingBucket, bucketID != .archived else { return }
          let ancestors = Set(SidebarBranchNesting.ancestorPrefixes(of: branchName))
          guard !ancestors.isEmpty,
            var bucket = sidebar.sections[repositoryID]?.buckets[bucketID]
          else { return }
          let next = bucket.collapsedBranchPrefixes.subtracting(ancestors)
          guard next != bucket.collapsedBranchPrefixes else { return }
          bucket.collapsedBranchPrefixes = next
          sidebar.sections[repositoryID]?.buckets[bucketID] = bucket
        }
        state.nextPendingSidebarRevealID += 1
        state.pendingSidebarReveal = .init(id: state.nextPendingSidebarRevealID, worktreeID: worktreeID)
        return .none

      case .revealHoistedWorktreeInSidebar(let worktreeID):
        // The target lives in a highlight section, which is never collapsed,
        // so no section / branch-prefix uncollapse is needed.
        state.nextPendingSidebarRevealID += 1
        state.pendingSidebarReveal = .init(id: state.nextPendingSidebarRevealID, worktreeID: worktreeID)
        return .none

      case .consumePendingSidebarReveal(let pendingSidebarRevealID):
        guard state.pendingSidebarReveal?.id == pendingSidebarRevealID else { return .none }
        state.pendingSidebarReveal = nil
        return .none

      case .createRandomWorktree:
        guard let repository = state.repositoryForWorktreeCreation else {
          let message: String
          if state.repositories.isEmpty {
            message = "Open a repository to create a worktree."
          } else if state.selectedWorktreeID == nil && state.repositories.count > 1 {
            message = "Select a worktree to choose which repository to use."
          } else {
            message = "Unable to resolve a repository for the new worktree."
          }
          state.alert = messageAlert(title: "Unable to create worktree", message: message)
          return .none
        }
        return .send(.createRandomWorktreeInRepository(repository.id))

      case .createRandomWorktreeInRepository(let repositoryID, let pendingID):
        // Drain a parked CLI ack when a guard rejects, so it can't only time out.
        let cancelAck: Effect<Action> =
          pendingID.map { .send(.cliWorktreeAckCancelled(pendingID: $0)) } ?? .none
        guard let repository = state.repositories[id: repositoryID] else {
          state.alert = messageAlert(
            title: "Unable to create worktree",
            message: "Unable to resolve a repository for the new worktree."
          )
          return cancelAck
        }
        // Worktree creation needs a git repository. Folder-kind entries
        // surface the same menu / hotkey / deeplink path, so reject
        // them up front with a clear alert instead of letting the
        // request fall into `gitClient.createWorktreeStream` and fail
        // with a raw subprocess error.
        if !repository.isGitRepository {
          state.alert = messageAlert(
            title: "Unable to create worktree",
            message: "Worktrees are only supported for git repositories."
          )
          return cancelAck
        }
        if state.removingRepositoryIDs[repository.id] != nil {
          state.alert = messageAlert(
            title: "Unable to create worktree",
            message: "This repository is being removed."
          )
          return cancelAck
        }
        @Shared(.settingsFile) var settingsFile
        if !settingsFile.global.promptForWorktreeCreation {
          return .merge(
            .cancel(id: CancelID.worktreePromptLoad),
            .send(
              .createWorktreeInRepository(
                repositoryID: repository.id,
                nameSource: .random,
                baseRefSource: .repositorySetting,
                fetchOrigin: settingsFile.global.fetchOriginBeforeWorktreeCreation,
                pendingID: pendingID
              )
            )
          )
        }
        // The interactive prompt mints the worktree later; park the CLI ack id so
        // the prompt's create threads it and a cancel / dismiss drains it. A new
        // prompt supersedes any prior one (single slot), so drain a stale parked
        // id first instead of orphaning it (covers a user prompt replacing a CLI
        // one, and back-to-back CLI prompts).
        let supersededAckEffects: [Effect<Action>] = state.cliWorktreeAckPendingIDs.values.map {
          .send(.cliWorktreeAckCancelled(pendingID: $0))
        }
        state.cliWorktreeAckPendingIDs.removeAll()
        if let pendingID {
          state.cliWorktreeAckPendingIDs[repository.id] = pendingID
        }
        @Shared(.repositorySettings(repository.rootURL, host: repository.host)) var repositorySettings
        let selectedBaseRef = repositorySettings.worktreeBaseRef
        // Remote repos load the prompt's branch lists over ssh (host-aware
        // client); local uses the injected client. The dialog loads these in
        // the background, so the ssh round-trips (multiplexed over the warm
        // ControlMaster) don't block presentation.
        let gitClient = gitClient(for: repository)
        let rootURL = repository.rootURL
        // Resolve the cheap quick-picks (auto ref + matching local
        // branch) and present the prompt right away, then load the
        // full local / remote branch lists in the background so the
        // dialog never blocks on `git for-each-ref`.
        let loadEffect: Effect<Action> = .run { send in
          let automaticBaseRef = await gitClient.automaticWorktreeBaseRef(rootURL) ?? "HEAD"
          guard !Task.isCancelled else {
            return
          }
          let remoteNames = (try? await gitClient.remoteNames(rootURL)) ?? []
          let defaultBranch = GitReferenceQueries.localBranchName(
            fromRemoteRef: automaticBaseRef,
            remoteNames: remoteNames
          )
          guard !Task.isCancelled else {
            return
          }
          await send(
            .promptedWorktreeCreationDataLoaded(
              repositoryID: repositoryID,
              automaticBaseRef: automaticBaseRef,
              defaultBranch: defaultBranch,
              remoteNames: remoteNames,
              selectedBaseRef: selectedBaseRef
            )
          )
          let inventory =
            (try? await gitClient.branchInventory(rootURL, remoteNames)) ?? GitBranchInventory()
          guard !Task.isCancelled else {
            return
          }
          await send(
            .promptedWorktreeBranchesLoaded(repositoryID: repositoryID, inventory: inventory)
          )
        }
        .cancellable(id: CancelID.worktreePromptLoad, cancelInFlight: true)
        return .merge(supersededAckEffects + [loadEffect])

      case .promptedWorktreeCreationDataLoaded(
        let repositoryID,
        let automaticBaseRef,
        let defaultBranch,
        let remoteNames,
        let selectedBaseRef
      ):
        guard let repository = state.repositories[id: repositoryID] else {
          // The repo vanished mid-load, so the prompt never opens; drain the
          // parked ack instead of leaving it for the watchdog.
          let ackPendingID = state.cliWorktreeAckPendingIDs.removeValue(forKey: repositoryID)
          return ackPendingID.map { .send(.cliWorktreeAckCancelled(pendingID: $0)) } ?? .none
        }
        @Shared(.settingsFile) var promptSettingsFile
        @Shared(.repositorySettings(repository.rootURL, host: repository.host)) var promptRepositorySettings
        let defaultWorktreeBaseDirectory = SupacodePaths.worktreeBaseDirectory(
          for: repository.rootURL,
          globalDefaultPath: promptSettingsFile.global.defaultWorktreeBaseDirectoryPath,
          repositoryOverridePath: promptRepositorySettings.worktreeBaseDirectoryPath
        )
        .path(percentEncoded: false)
        state.worktreeCreationPrompt = WorktreeCreationPromptFeature.State(
          repositoryID: repository.id,
          repositoryRootURL: repository.rootURL,
          repositoryName: repository.name,
          automaticBaseRef: automaticBaseRef,
          defaultBranch: defaultBranch,
          remoteNames: remoteNames,
          branchMenu: nil,
          branchName: "",
          selectedBaseRef: selectedBaseRef,
          fetchOrigin: promptSettingsFile.global.fetchOriginBeforeWorktreeCreation,
          defaultWorktreeBaseDirectory: defaultWorktreeBaseDirectory,
          validationMessage: nil
        )
        return .none

      case .promptedWorktreeBranchesLoaded(let repositoryID, let inventory):
        guard var prompt = state.worktreeCreationPrompt, prompt.repositoryID == repositoryID else {
          return .none
        }
        // Drop the default-branch quick pick if no local branch of that name
        // actually exists (e.g. a fresh clone with only `origin/main`), so it
        // can't submit a missing ref. Guard on a non-empty inventory so a
        // failed load doesn't hide a valid quick pick.
        if !inventory.isEmpty, let defaultBranch = prompt.defaultBranch,
          !inventory.localBranches.contains(defaultBranch)
        {
          prompt.defaultBranch = nil
        }
        prompt.branchMenu = BaseRefBranchMenu(
          inventory: inventory,
          hoistedLocalBranch: prompt.defaultBranch
        )
        // A persisted base ref (from repository settings) can point at a branch
        // that no longer exists. Fall back to Auto so the prompt doesn't show an
        // invisible selection and submit a dead ref to `git worktree add`. Only
        // reconcile against a non-empty inventory so a failed load doesn't wipe a
        // still-valid ref.
        if let selectedBaseRef = prompt.selectedBaseRef, !inventory.isEmpty,
          selectedBaseRef != prompt.automaticBaseRef,
          !inventory.contains(ref: selectedBaseRef)
        {
          prompt.selectedBaseRef = nil
        }
        state.worktreeCreationPrompt = prompt
        return .none

      case .worktreeCreationPrompt(.presented(.delegate(.cancel))):
        var cancelEffects: [Effect<Action>] = [
          .cancel(id: CancelID.worktreePromptLoad),
          .cancel(id: CancelID.worktreePromptValidation),
        ]
        if let repositoryID = state.worktreeCreationPrompt?.repositoryID {
          state.dropPendingCustomization(repositoryID: repositoryID)
          if let ackPendingID = state.cliWorktreeAckPendingIDs.removeValue(forKey: repositoryID) {
            cancelEffects.append(.send(.cliWorktreeAckCancelled(pendingID: ackPendingID)))
          }
        }
        state.worktreeCreationPrompt = nil
        return .merge(cancelEffects)

      case .worktreeCreationPrompt(
        .presented(
          .delegate(
            .submit(
              let repositoryID,
              let branchName,
              let baseRef,
              let fetchOrigin,
              let placement,
              let title,
              let color
            )
          )
        )
      ):
        // Overwrite (or clear) any stale entry for the same (repo, branch) so a user who typed a
        // title, hit a validation error, blanked the field, and re-submitted doesn't keep the
        // dropped value alive.
        if title != nil || color != nil {
          state.pendingCreationCustomizations[repositoryID, default: [:]][branchName] =
            PendingWorktree.Customization(title: title, color: color)
        } else {
          state.dropPendingCustomization(repositoryID: repositoryID, branchName: branchName)
        }
        return .send(
          .startPromptedWorktreeCreation(
            repositoryID: repositoryID,
            branchName: branchName,
            baseRef: baseRef,
            fetchOrigin: fetchOrigin,
            placement: placement
          )
        )

      case .startPromptedWorktreeCreation(
        let repositoryID,
        let branchName,
        let baseRef,
        let fetchOrigin,
        let placement
      ):
        guard let repository = state.repositories[id: repositoryID] else {
          state.worktreeCreationPrompt = nil
          state.alert = messageAlert(
            title: "Unable to create worktree",
            message: "Unable to resolve a repository for the new worktree."
          )
          // Drain the just-stashed customization so a later retry with the same name doesn't pick
          // up the orphaned entry.
          state.dropPendingCustomization(repositoryID: repositoryID, branchName: branchName)
          let ackPendingID = state.cliWorktreeAckPendingIDs.removeValue(forKey: repositoryID)
          return ackPendingID.map { .send(.cliWorktreeAckCancelled(pendingID: $0)) } ?? .none
        }
        state.worktreeCreationPrompt?.validationMessage = nil
        state.worktreeCreationPrompt?.isValidating = true
        let normalizedBranchName = branchName.lowercased()
        if repository.worktrees.contains(where: { $0.name.lowercased() == normalizedBranchName }) {
          state.worktreeCreationPrompt?.isValidating = false
          state.worktreeCreationPrompt?.validationMessage = "Branch name already exists."
          // Synchronous duplicate rejection. Drop the stashed customization so it can't be
          // re-applied if the user retries with a different branch name.
          state.dropPendingCustomization(repositoryID: repositoryID, branchName: branchName)
          return .none
        }
        let gitClient = gitClient(for: repository)
        let rootURL = repository.rootURL
        return .run { send in
          let localBranchNames = (try? await gitClient.localBranchNames(rootURL)) ?? []
          let duplicateMessage =
            localBranchNames.contains(normalizedBranchName)
            ? "Branch name already exists."
            : nil
          await send(
            .promptedWorktreeCreationChecked(
              repositoryID: repositoryID,
              branchName: branchName,
              baseRef: baseRef,
              fetchOrigin: fetchOrigin,
              placement: placement,
              duplicateMessage: duplicateMessage
            )
          )
        }
        .cancellable(id: CancelID.worktreePromptValidation, cancelInFlight: true)

      case .promptedWorktreeCreationChecked(
        let repositoryID,
        let branchName,
        let baseRef,
        let fetchOrigin,
        let placement,
        let duplicateMessage
      ):
        guard let prompt = state.worktreeCreationPrompt, prompt.repositoryID == repositoryID else {
          return .none
        }
        state.worktreeCreationPrompt?.isValidating = false
        if let duplicateMessage {
          state.worktreeCreationPrompt?.validationMessage = duplicateMessage
          // Async-validation duplicate rejection. Same drop reasoning as the sync path.
          state.dropPendingCustomization(repositoryID: repositoryID, branchName: branchName)
          return .none
        }
        state.worktreeCreationPrompt = nil
        // Consume the parked CLI ack id so it threads into this creation and the
        // subsequent success-path dismiss doesn't mistake it for a cancel.
        let ackPendingID = state.cliWorktreeAckPendingIDs.removeValue(forKey: repositoryID)
        return .send(
          .createWorktreeInRepository(
            repositoryID: repositoryID,
            nameSource: .explicit(branchName),
            baseRefSource: .explicit(baseRef),
            fetchOrigin: fetchOrigin,
            placement: placement,
            pendingID: ackPendingID
          )
        )

      case .createWorktreeInRepository:
        // Real handling lives in `worktreeCreateInRepoReducer` (combined below) to keep
        // `body` under the type-checker's complexity limit.
        return .none

      case .cliWorktreeAckCancelled:
        // Observed by AppFeature to drain the parked CLI ack; no local effect.
        return .none

      case .worktreeCreationPrompt(.dismiss):
        // Don't drain `pendingCreationCustomizations` here: `.dismiss` also fires on the success
        // path (when the reducer nils the prompt after validation passes) and the in-flight
        // creation still needs the customization. Only `.cancel` is an explicit user back-out.
        var dismissEffects: [Effect<Action>] = [
          .cancel(id: CancelID.worktreePromptLoad),
          .cancel(id: CancelID.worktreePromptValidation),
        ]
        // A still-parked ack means this dismiss is a back-out (the success path
        // consumes it first), so drain it instead of stranding it.
        if let repositoryID = state.worktreeCreationPrompt?.repositoryID,
          let ackPendingID = state.cliWorktreeAckPendingIDs.removeValue(forKey: repositoryID)
        {
          dismissEffects.append(.send(.cliWorktreeAckCancelled(pendingID: ackPendingID)))
        }
        state.worktreeCreationPrompt = nil
        return .merge(dismissEffects)

      case .worktreeCreationPrompt:
        return .none

      case .pendingWorktreeProgressUpdated(let id, let progress):
        guard state.updatePendingWorktreeProgress(id, progress: progress) else { return .none }
        Self.syncSidebar(&state)
        return .none

      case .createRandomWorktreeSucceeded(
        let worktree,
        let repositoryID,
        let pendingID
      ):
        analyticsClient.capture("worktree_created", nil)
        // Capture the pending row's customization BEFORE the pending drops,
        // then forward it to the bucketed Item so reconcile renders the
        // user-typed title / color from the very first paint after the
        // pending row swaps to the real worktree.
        let carriedCustomization = state.pendingWorktrees.first(where: { $0.id == pendingID })?.customization
        state.removePendingWorktree(pendingID)
        if state.selection == .worktree(pendingID) {
          // History was already recorded when the pending row was
          // selected (real → pending). Treat the swap into the real
          // worktree id as a continuation of that same navigation
          // so the back stack ends with the real id, not the
          // throwaway pending id.
          state.setSingleWorktreeSelection(worktree.id, recordHistory: false)
        }
        state.insertWorktree(worktree, repositoryID: repositoryID)
        if let carriedCustomization, carriedCustomization.title != nil || carriedCustomization.color != nil {
          // Seed customization into whatever bucket currently holds the row (falls back to
          // `.unpinned` for a brand-new worktree). The bucket probe avoids manufacturing a
          // phantom double-bucket entry against a persisted `.pinned` Item.
          state.$sidebar.withLock { sidebar in
            sidebar.mergeCustomization(
              title: carriedCustomization.title,
              color: carriedCustomization.color,
              worktree: worktree.id,
              in: repositoryID
            )
          }
        }
        Self.syncSidebar(&state)
        // Synchronous so the detail body never observes a brief `.idle` window
        // between the real-worktree swap and the setup-script path.
        state.sidebarItems[id: worktree.id]?.lifecycle = .pending
        return .merge(
          .send(.sidebarItems(.element(id: worktree.id, action: .focusTerminalRequested))),
          .send(.reloadRepositories(animated: false)),
          .send(.delegate(.repositoriesChanged(state.repositories))),
          .send(.delegate(.selectedWorktreeChanged(state.worktree(for: state.selectedWorktreeID)))),
          .send(.delegate(.worktreeCreated(worktree)))
        )

      case .createRandomWorktreeFailed(
        let title,
        let message,
        let pendingID,
        let previousSelection,
        let repositoryID,
        let name,
        let baseDirectory
      ):
        let previousSelectedWorktree = state.worktree(for: previousSelection)
        state.removePendingWorktree(pendingID)
        state.restoreSelection(previousSelection, pendingID: pendingID)
        let cleanup = state.cleanupFailedWorktree(
          repositoryID: repositoryID,
          name: name,
          baseDirectory: baseDirectory,
        )
        state.alert = messageAlert(title: title, message: message)
        let selectedWorktree = state.worktree(for: state.selectedWorktreeID)
        let selectionChanged = state.hasSelectionChanged(
          previousSelectionID: previousSelection,
          previousSelectedWorktree: previousSelectedWorktree,
          selectedWorktreeID: state.selectedWorktreeID,
          selectedWorktree: selectedWorktree,
        )
        var effects: [Effect<Action>] = []
        if cleanup.didRemoveWorktree {
          effects.append(.send(.delegate(.repositoriesChanged(state.repositories))))
        }
        if selectionChanged {
          effects.append(.send(.delegate(.selectedWorktreeChanged(selectedWorktree))))
        }
        // Sidebar-state mutations in `cleanupWorktreeState` already
        // went through `$sidebar.withLock`, so no per-slice save
        // effects are needed here.
        if let cleanupWorktree = cleanup.worktree {
          let cleanupClient = gitClient(for: cleanupWorktree)
          effects.append(
            .run { send in
              _ = try? await cleanupClient.removeWorktree(cleanupWorktree, true)
              await send(.reloadRepositories(animated: true))
            }
          )
        }
        return .merge(effects)

      case .consumeSetupScript(let id):
        guard state.sidebarItems[id: id]?.lifecycle == .pending else { return .none }
        return .send(.sidebarItems(.element(id: id, action: .lifecycleChanged(.idle))))

      case .consumeTerminalFocus(let id):
        return .send(.sidebarItems(.element(id: id, action: .focusTerminalConsumed)))

      case .requestArchiveWorktree, .requestArchiveWorktrees, .scriptCompleted, .archiveWorktreeConfirmed,
        .archiveScriptCompleted, .archiveWorktreeApply, .unarchiveWorktree, .requestDeleteSidebarItems:
        // Real handling lives in `worktreeRemovalReducer` (combined below) so `body` stays under the
        // type-checker's complexity limit; the `.alert(.presented(.confirm…))` arms there are matched
        // here by the trailing `.alert` catch-all returning `.none`.
        return .none

      case .deleteSidebarItemConfirmed, .deleteScriptCompleted, .deleteWorktreeApply, .worktreeDeleted,
        .repositoriesMoved, .pinnedWorktreesMoved, .unpinnedWorktreesMoved, .deleteWorktreeFailed,
        .requestDeleteRepository, .requestRemoveFailedRepository, .removeFailedRepository,
        .repositoryRemovalCompleted, .repositoriesRemoved:
        // Real handling lives in `worktreeRemovalReducer` (combined below) so `body` stays under
        // the type-checker's complexity limit. The two `.alert(.presented(.confirm…))` arms in that
        // reducer are matched here by the trailing `.alert` catch-all returning `.none`.
        return .none

      case .pinWorktree, .unpinWorktree, .presentAlert, .showToast, .dismissToast, .delayedPullRequestRefresh,
        .toggleInspectorPane, .setInspectorPresented,
        .worktreeInfoEvent:
        // Real handling lives in `worktreeNotificationReducer` (combined below) to keep `body`
        // under the type-checker's complexity limit.
        return .none

      case .refreshGithubIntegrationAvailability, .githubIntegrationAvailabilityUpdated,
        .repositoryPullRequestRefreshCompleted, .worktreeBranchNameLoaded, .worktreeLineChangesLoaded,
        .repositoryPullRequestsLoaded, .pullRequestAction, .setGithubIntegrationEnabled, .setMergedWorktreeAction,
        .setAutoDeleteArchivedWorktreesAfterDays, .autoDeleteExpiredArchivedWorktrees, .setMoveNotifiedWorktreeToTop,
        .setInstalledOpenActions, .openActionSettingsChanged, .resolveOpenActions, .openActionsResolved:
        // Real handling lives in `githubIntegrationReducer` (combined below) to keep `body`
        // under the type-checker's complexity limit.
        return .none

      case .openRepositorySettings(let repositoryID):
        return .send(.delegate(.openRepositorySettings(repositoryID)))

      case .requestCustomizeRepository(let repositoryID):
        guard let repository = state.repositories[id: repositoryID] else {
          return .none
        }
        // Folder-kind repositories render through `SidebarFolderRow`,
        // which has no section header to tint and no ellipsis menu
        // to expose. Guard the action so a future deeplink or
        // command-palette hookup can't write customization that the
        // sidebar would never display.
        guard repository.isGitRepository else {
          return .none
        }
        // The sidebar disables customize while the repo is being removed; the
        // palette has no disabled state, so gate the request here too.
        guard state.removingRepositoryIDs[repositoryID] == nil else {
          return .none
        }
        let section = state.sidebar.sections[repositoryID]
        let storedTitle = section?.title ?? ""
        let storedColor = section?.color
        state.repositoryCustomization = RepositoryCustomizationFeature.State(
          repositoryID: repositoryID,
          defaultName: repository.name,
          title: storedTitle,
          color: storedColor
        )
        return .none

      case .repositoryCustomization(.presented(.delegate(.cancel))):
        state.repositoryCustomization = nil
        return .none

      case .repositoryCustomization(.presented(.delegate(.save(let repositoryID, let title, let color)))):
        state.$sidebar.withLock { sidebar in
          sidebar.sections[repositoryID, default: .init()].title = title
          sidebar.sections[repositoryID, default: .init()].color = color
        }
        state.repositoryCustomization = nil
        return .none

      case .repositoryCustomization(.dismiss):
        state.repositoryCustomization = nil
        return .none

      case .repositoryCustomization:
        return .none

      case .requestCustomizeWorktree,
        .setWorktreeAppearance,
        .worktreeCustomization:
        // Handled by `WorktreeCustomizationParentReducer` below; main switch is at type-checker
        // capacity, so the customization arms are split out into a dedicated reducer.
        return .none

      case .requestRenameBranch(let worktreeID, let repositoryID):
        guard let repository = state.repositories[id: repositoryID],
          repository.isGitRepository,
          let worktree = repository.worktrees.first(where: { $0.id == worktreeID }),
          !worktree.isMissing,
          worktree.isAttached,
          !worktree.name.isEmpty
        else {
          return .none
        }
        guard state.sidebarItems[id: worktreeID]?.lifecycle == .idle else {
          return .none
        }
        state.renameBranchPrompt = RenameBranchFeature.State(
          worktreeID: worktreeID,
          repositoryID: repositoryID,
          repositoryRootURL: repository.rootURL,
          host: worktree.host,
          currentName: worktree.name
        )
        return .none

      case .renameBranchPrompt(.presented(.delegate(.cancel))):
        state.renameBranchPrompt = nil
        return .none

      case .renameBranchPrompt(.presented(.delegate(.renamed(let worktreeID, let repositoryID, let newName)))):
        state.updateWorktreeName(worktreeID, name: newName)
        Self.syncSidebar(&state)
        state.renameBranchPrompt = nil
        // Refresh only the renamed row's PR; siblings still point at their
        // own branches. The HEAD watcher re-emits the name authoritatively.
        guard let repository = state.repositories[id: repositoryID] else { return .none }
        return .send(
          .worktreeInfoEvent(
            .repositoryPullRequestRefresh(
              repositoryRootURL: repository.rootURL,
              worktreeIDs: [worktreeID]
            )
          )
        )

      case .renameBranchPrompt(.dismiss):
        state.renameBranchPrompt = nil
        return .none

      case .renameBranchPrompt:
        return .none

      case .contextMenuOpenWorktree(let worktreeID, let action):
        return .send(.delegate(.openWorktreeInApp(worktreeID, action)))

      case .alert(.presented(.viewTerminalTab(let worktreeID, let tabId))):
        return .merge(
          .send(.selectWorktree(worktreeID, focusTerminal: true)),
          .send(.delegate(.selectTerminalTab(worktreeID, tabId: tabId)))
        )

      case .alert(.dismiss):
        state.alert = nil
        return .none

      case .alert:
        return .none

      case .delegate:
        return .none

      case .sidebarItems(.element(id: let id, action: .lifecycleChanged(let lifecycle))):
        // Dismiss the rename sheet if the row enters a wind-down state.
        // `.pending` stays eligible since the setup script can co-exist with rename.
        if state.renameBranchPrompt?.worktreeID == id, lifecycle.isTerminating {
          state.renameBranchPrompt = nil
        }
        return .none

      case .sidebarItems:
        return .none
      }
    }
    // These presentation `ifLet`s hang off the main `Reduce` so each child runs before the
    // parent handles its `.delegate` / `.dismiss` and nils the state. The `.worktreeCustomization`
    // ifLet sits on `worktreeCustomizationReducer` below (same child-first ordering, but kept off
    // the main `Reduce` so the `body` expression stays within the type-checker's complexity limit).
    .forEach(\.sidebarItems, action: \.sidebarItems) {
      SidebarItemFeature()
    }
    .ifLet(\.$worktreeCreationPrompt, action: \.worktreeCreationPrompt) {
      WorktreeCreationPromptFeature()
    }
    .ifLet(\.$repositoryCustomization, action: \.repositoryCustomization) {
      RepositoryCustomizationFeature()
    }
    .ifLet(\.$renameBranchPrompt, action: \.renameBranchPrompt) {
      RenameBranchFeature()
    }
    Self.worktreeCustomizationReducer
      .ifLet(\.$worktreeCustomization, action: \.worktreeCustomization) {
        WorktreeCustomizationFeature()
      }
    // Dedicated reducer + chained `ifLet` so the form's child reducer runs
    // before the delegate handler nils the presented state (mirrors the
    // worktree-customization pattern, and keeps `body` under the type-checker
    // complexity limit).
    Self.remoteConnectionFormReducer
      .ifLet(\.$remoteConnectionForm, action: \.remoteConnectionForm) {
        RemoteConnectionFormFeature()
      }
    Self.cloneRepositoryFormReducer
      .ifLet(\.$cloneRepositoryForm, action: \.cloneRepositoryForm) {
        CloneRepositoryFormFeature()
      }
    worktreeArchiveReducer
    worktreeRemovalReducer
    worktreeCreateInRepoReducer
    worktreeNotificationReducer
    githubIntegrationReducer
    // Targeted post-reduce hook: only the actions that demonstrably touch
    // structure inputs trigger a recompute. The Equatable diff inside the
    // helper suppresses no-op rebuilds at the SwiftUI layer. Gated on
    // `\.sidebarStructureAutoRecompute` (defaults to true everywhere); a few
    // legacy tests that don't care about sidebar layout opt out via
    // `withDependencies`, and the same knob parks the open-action resolution
    // effect for them.
    //
    // The open-action bits launch an effect rather than a recompute: the map is
    // read off disk, so `applyCacheRecomputes` must stay pure.
    Reduce { state, action in
      @Dependency(\.sidebarStructureAutoRecompute) var autoRecompute
      guard autoRecompute else { return .none }
      let invalidations = action.cacheInvalidations
      state.applyCacheRecomputes(invalidations)
      guard invalidations.contains(.openActionResolution) else { return .none }
      state.seedUnresolvedOpenActions()
      return Self.resolveOpenActionsEffect(state: state)
    }
  }

  private func refreshRepositoryPullRequests(
    repositoryID: Repository.ID,
    repositoryRootURL: URL,
    worktrees: [Worktree],
    branches: [String]
  ) -> Effect<Action> {
    let gitClient = gitClient
    let githubCLI = githubCLI
    return .run { send in
      guard
        let remoteInfo = await resolveRemoteInfo(
          repositoryRootURL: repositoryRootURL,
          githubCLI: githubCLI,
          gitClient: gitClient
        )
      else {
        await send(.repositoryPullRequestRefreshCompleted(repositoryID))
        return
      }
      do {
        let prsByBranch = try await githubCLI.batchPullRequests(
          remoteInfo.host,
          remoteInfo.owner,
          remoteInfo.repo,
          branches
        )
        var pullRequestsByWorktreeID: [Worktree.ID: GithubPullRequest?] = [:]
        for worktree in worktrees {
          pullRequestsByWorktreeID[worktree.id] = prsByBranch[worktree.name]
        }
        await send(
          .repositoryPullRequestsLoaded(
            repositoryID: repositoryID,
            pullRequestsByWorktreeID: pullRequestsByWorktreeID
          )
        )
      } catch {
        await send(.repositoryPullRequestRefreshCompleted(repositoryID))
        return
      }
      await send(.repositoryPullRequestRefreshCompleted(repositoryID))
    }
  }

  private func loadRepositories(_ roots: [URL], animated: Bool = false) -> Effect<Action> {
    let gitClient = gitClient
    return .run { [animated, roots] send in
      // Each reconcile shells out independently; parallel to keep load latency flat.
      await withTaskGroup(of: Void.self) { group in
        for root in roots {
          group.addTask { await gitClient.reconcileSupacodeLocks(root) }
        }
      }
      let loadResult = await loadRepositoriesData(roots)
      await send(.gitEnvironmentChanged(loadResult.environmentError))
      await send(
        .repositoriesLoaded(
          loadResult.repositories,
          failures: loadResult.failures,
          roots: roots,
          animated: animated
        )
      )
    }
    .cancellable(id: CancelID.load, cancelInFlight: true)
  }

  private static func mergePersistedRemoteRepositories(
    into repositories: [Repository],
    existingState state: State
  ) -> RemoteRepositoryMergeResult {
    // Parse persisted remote ids once into (repoID, host, path), dropping any
    // that don't parse as a remote authority.
    let remoteRoots: [ParsedRemoteRoot] =
      persistedRemoteRepositoryRoots().compactMap { root in
        guard let (host, remotePath) = parseRemoteRoot(root) else {
          repositoriesLogger.warning("Skipping unparseable persisted remote id: \(root).")
          return nil
        }
        return ParsedRemoteRoot(
          repoID: remoteRepositoryID(host: host, remotePath: remotePath), host: host, remotePath: remotePath)
      }
    var persistedRemoteIDs: Set<Repository.ID> = []
    for root in remoteRoots {
      persistedRemoteIDs.insert(root.repoID)
    }

    var mergedRepositories: [Repository] = []
    var indexesByID: [Repository.ID: Int] = [:]
    for repository in repositories {
      if repository.host != nil, !persistedRemoteIDs.contains(repository.id) {
        continue
      }
      guard indexesByID[repository.id] == nil else { continue }
      indexesByID[repository.id] = mergedRepositories.count
      mergedRepositories.append(repository)
    }

    guard !remoteRoots.isEmpty else {
      return RemoteRepositoryMergeResult(
        repositories: mergedRepositories,
        resolvingIDs: []
      )
    }

    var resolvingIDs: Set<Repository.ID> = []
    var seenRemoteIDs: Set<Repository.ID> = []
    for root in remoteRoots {
      let repoID = root.repoID
      // Two ids can collide (e.g. an edit made them match); keep the first so
      // the IdentifiedArray below can't trap.
      guard seenRemoteIDs.insert(repoID).inserted else { continue }
      if let index = indexesByID[repoID] {
        if mergedRepositories[index].worktrees.isEmpty {
          resolvingIDs.insert(repoID)
        }
        continue
      }
      if let existing = state.repositories[id: repoID], !existing.worktrees.isEmpty {
        indexesByID[repoID] = mergedRepositories.count
        mergedRepositories.append(existing)
      } else {
        indexesByID[repoID] = mergedRepositories.count
        mergedRepositories.append(
          remotePlaceholderRepository(host: root.host, remotePath: root.remotePath, repoID: repoID))
        resolvingIDs.insert(repoID)
      }
    }
    return RemoteRepositoryMergeResult(
      repositories: mergedRepositories,
      resolvingIDs: resolvingIDs
    )
  }

  private struct RemoteRepositoryMergeResult: Sendable {
    let repositories: [Repository]
    let resolvingIDs: Set<Repository.ID>
  }

  /// A persisted remote root parsed into its derived repo id, host, and path.
  private struct ParsedRemoteRoot {
    let repoID: Repository.ID
    let host: RemoteHost
    let remotePath: String
  }

  private struct WorktreesFetchResult: Sendable {
    let root: URL
    let isGitRepository: Bool
    let worktrees: [Worktree]?
    let errorMessage: String?
  }

  /// The id (working-directory path) of the first worktree that repeats one
  /// already seen, or `nil` when every id is unique. A non-nil result signals a
  /// corrupt repo, since a healthy repository never repeats a path.
  nonisolated static func firstDuplicateWorktreeID(in worktrees: [Worktree]) -> Worktree.ID? {
    var seen: Set<Worktree.ID> = []
    return worktrees.first(where: { !seen.insert($0.id).inserted })?.id
  }

  /// Failure-row copy for a repository whose worktree listing names the same
  /// path more than once.
  nonisolated static func duplicateWorktreePathMessage(path: String) -> String {
    "This repository lists more than one worktree at the same path (\(path)). "
      + "Its git configuration may be corrupt (for example a stale core.worktree). "
      + "Repair the repository and reopen it."
  }

  /// Fetch and classify one root's worktree listing for the loader. Static +
  /// `gitClient`-passed so it runs off-main inside the load task group.
  nonisolated private static func worktreesFetchResult(
    for root: URL,
    gitClient: GitClientDependency
  ) async -> WorktreesFetchResult {
    // Check existence first so a removed / unmounted root surfaces a failure
    // row instead of being synthesized as an empty folder (a missing path makes
    // `gitClient.isGitRepository` return `false`, hiding the real problem).
    // Routed through the dependency so fake `/tmp/...` test paths can override
    // it.
    let exists = await gitClient.rootDirectoryExists(root)
    guard exists else {
      return WorktreesFetchResult(
        root: root,
        isGitRepository: false,
        worktrees: nil,
        errorMessage:
          "Directory not found at \(root.standardizedFileURL.path(percentEncoded: false)). "
          + "It may have been moved or deleted."
      )
    }
    // Classify through the git client so tests can override without touching the
    // filesystem.
    let isGit = await gitClient.isGitRepository(root)
    guard isGit else {
      return WorktreesFetchResult(
        root: root, isGitRepository: false, worktrees: [], errorMessage: nil)
    }
    do {
      let worktrees = try await gitClient.worktrees(root)
      // A duplicate path means the repo's git config is corrupt (e.g. a stale
      // `core.worktree`). Refuse it and surface a failure rather than guess
      // which of the colliding entries is real.
      if let duplicate = firstDuplicateWorktreeID(in: worktrees) {
        return WorktreesFetchResult(
          root: root,
          isGitRepository: true,
          worktrees: nil,
          errorMessage: duplicateWorktreePathMessage(path: duplicate.rawValue)
        )
      }
      return WorktreesFetchResult(
        root: root, isGitRepository: true, worktrees: worktrees, errorMessage: nil)
    } catch {
      // Any git listing failure (blocked binary, transient error, or a real repo
      // problem). Report it as a failed git root and let the loader's
      // `git --version` probe decide, once, whether git itself is blocked.
      return WorktreesFetchResult(
        root: root,
        isGitRepository: true,
        worktrees: nil,
        errorMessage: error.localizedDescription
      )
    }
  }

  /// A git root whose listing failed, held until the `git --version` probe
  /// decides if git is really blocked (suppress under the banner) or working
  /// (surface `message` as a real failure row).
  private struct DeferredGitFailure {
    let rootID: Repository.ID
    let message: String
  }

  /// Result of a local repository load. A struct rather than a tuple so the
  /// three payloads travel together without tripping the `large_tuple` lint.
  private struct RepositoriesLoadResult {
    let repositories: [Repository]
    let failures: [LoadFailure]
    let environmentError: GitEnvironmentError?
  }

  private func loadRepositoriesData(_ roots: [URL]) async -> RepositoriesLoadResult {
    let fetchResults = await withTaskGroup(of: WorktreesFetchResult.self) { group in
      for root in roots {
        let gitClient = self.gitClient
        group.addTask {
          await Self.worktreesFetchResult(for: root, gitClient: gitClient)
        }
      }

      var resultsByRootID: [Repository.ID: WorktreesFetchResult] = [:]
      for await result in group {
        let rootID = RepositoryID(result.root.standardizedFileURL.path(percentEncoded: false))
        resultsByRootID[rootID] = result
      }
      return resultsByRootID
    }

    var loaded: [Repository] = []
    var failures: [LoadFailure] = []
    // Git roots that failed to list, deferred until the probe decides whether
    // git itself is blocked (see below).
    var deferredGitFailures: [DeferredGitFailure] = []
    for root in roots {
      let normalizedRoot = root.standardizedFileURL
      let rootID = RepositoryID(normalizedRoot.path(percentEncoded: false))
      guard let result = fetchResults[rootID] else { continue }
      let name = Repository.name(for: normalizedRoot)
      if result.isGitRepository {
        if let worktrees = result.worktrees {
          let repository = Repository(
            id: rootID,
            rootURL: normalizedRoot,
            name: name,
            worktrees: IdentifiedArray(uniqueElements: worktrees),
            isGitRepository: true
          )
          loaded.append(repository)
        } else {
          // A real block fails every git root, and we can't judge a repo broken
          // while git is down, so defer the verdict to the probe below.
          deferredGitFailures.append(
            DeferredGitFailure(rootID: rootID, message: result.errorMessage ?? "Unknown error"))
        }
      } else if let errorMessage = result.errorMessage {
        // Non-git root with an error: the classifier couldn't open
        // the directory (missing / unmounted / unreadable).
        // Route through the same `LoadFailure` pipeline git
        // repos use so the sidebar shows the error row.
        failures.append(
          LoadFailure(rootID: rootID, message: errorMessage)
        )
      } else {
        // Folder repository: synthesize a single main-like worktree
        // so the existing sidebar selection + terminal plumbing keeps
        // working without new entity types.
        let synthetic = Worktree(
          id: Repository.folderWorktreeID(for: normalizedRoot),
          kind: .folder,
          name: name,
          detail: "",
          workingDirectory: normalizedRoot,
          repositoryRootURL: normalizedRoot,
          isAttached: false
        )
        let repository = Repository(
          id: rootID,
          rootURL: normalizedRoot,
          name: name,
          worktrees: IdentifiedArray(uniqueElements: [synthetic]),
          isGitRepository: false
        )
        loaded.append(repository)
      }
    }
    // If any git repo loaded, git demonstrably works. Otherwise a direct
    // `git --version` probe is the ground truth for whether git is
    // environment-blocked: locale-independent (so it doesn't depend on a repo's
    // stderr being English-matchable), and it disconfirms a repo error that
    // merely echoes a gate phrase. It also covers a folder-only / empty roster.
    // Blocked -> the deferred git failures become suppressed warning rows;
    // working -> they were real repo problems and surface as failure rows.
    var environmentError: GitEnvironmentError?
    if !loaded.contains(where: \.isGitRepository) {
      environmentError = await gitClient.checkGitEnvironment()
    }
    if environmentError == nil {
      for failure in deferredGitFailures {
        failures.append(LoadFailure(rootID: failure.rootID, message: failure.message))
      }
    }
    // Remote repositories are NOT resolved here: that SSH work runs
    // asynchronously after the load (`.resolveRemoteRepositories`) so an
    // unreachable host never blocks the initial sidebar. The `.repositoriesLoaded`
    // handler merges in their placeholders and triggers resolution.
    return RepositoriesLoadResult(
      repositories: loaded,
      failures: failures,
      environmentError: environmentError
    )
  }

  /// Customization transfer record produced by `prunedPendingWorktrees` and
  /// consumed by `seedCustomizationForDiscoveredWorktree`. A struct rather
  /// than a tuple so the two helpers can pass the payload around without
  /// tripping the `large_tuple` lint.
  private struct PendingCustomizationTransfer {
    let repositoryID: Repository.ID
    let worktreeName: String
    let customization: PendingWorktree.Customization
  }

  /// Filter `state.pendingWorktrees` against a freshly-loaded roster. Pending
  /// rows whose `worktreeName` matches a newly-discovered worktree are pruned
  /// and (when customized) hand their title / color to the caller for
  /// transfer onto the bucketed Item. Pending rows without a final name fall
  /// back to a count-based drop so the random-name path keeps its old shape.
  private func prunedPendingWorktrees(
    state: State,
    repositories: [Repository],
    repositoryIDs: Set<Repository.ID>
  ) -> ([PendingWorktree], [PendingCustomizationTransfer]) {
    let previousCounts = Dictionary(
      uniqueKeysWithValues: state.repositories.map { ($0.id, $0.worktrees.count) }
    )
    let newCounts = Dictionary(uniqueKeysWithValues: repositories.map { ($0.id, $0.worktrees.count) })
    var addedCounts: [Repository.ID: Int] = [:]
    for (id, newCount) in newCounts {
      let added = newCount - (previousCounts[id] ?? 0)
      if added > 0 { addedCounts[id] = added }
    }
    var remainingDiscoveredNamesByRepo: [Repository.ID: Set<String>] = [:]
    for repository in repositories {
      let previousNames = Set(state.repositories[id: repository.id]?.worktrees.map(\.name) ?? [])
      let added = Set(repository.worktrees.map(\.name)).subtracting(previousNames)
      if !added.isEmpty { remainingDiscoveredNamesByRepo[repository.id] = added }
    }
    var transfers: [PendingCustomizationTransfer] = []
    // Pass 1: consume name matches up front. This drains the discovered-name
    // set AND the count budget so the count-based fallback in pass 2 only
    // fires for the leftover budget, never for a discovered name that a
    // later pending row was going to match.
    var droppedPendingIDs: Set<Worktree.ID> = []
    for pending in state.pendingWorktrees {
      guard repositoryIDs.contains(pending.repositoryID),
        let pendingName = pending.progress.worktreeName,
        remainingDiscoveredNamesByRepo[pending.repositoryID]?.contains(pendingName) == true
      else { continue }
      remainingDiscoveredNamesByRepo[pending.repositoryID]?.remove(pendingName)
      if let customization = pending.customization,
        customization.title != nil || customization.color != nil
      {
        transfers.append(
          PendingCustomizationTransfer(
            repositoryID: pending.repositoryID,
            worktreeName: pendingName,
            customization: customization,
          )
        )
      }
      addedCounts[pending.repositoryID, default: 0] = max(0, (addedCounts[pending.repositoryID] ?? 0) - 1)
      droppedPendingIDs.insert(pending.id)
    }
    // Pass 2: count-based drop for the unnamed remainder. Named pending rows
    // only drop via pass 1's exact name match; otherwise concurrent creations
    // can prune the wrong row when only a sibling worktree appears.
    let filtered = state.pendingWorktrees.filter { pending in
      guard repositoryIDs.contains(pending.repositoryID) else { return false }
      if droppedPendingIDs.contains(pending.id) { return false }
      if pending.progress.worktreeName != nil { return true }
      guard let remaining = addedCounts[pending.repositoryID], remaining > 0 else { return true }
      addedCounts[pending.repositoryID] = remaining - 1
      return false
    }
    return (filtered, transfers)
  }

  /// Write each transferred pending customization onto the bucketed Item for
  /// the matching newly-discovered worktree. Skips fields the user has
  /// already set via Customize Worktree… so the bucketed Item stays
  /// authoritative once non-nil.
  private func seedCustomizationForDiscoveredWorktree(
    transfers: [PendingCustomizationTransfer],
    repositories: [Repository],
    state: inout State
  ) {
    guard !transfers.isEmpty else { return }
    state.$sidebar.withLock { sidebar in
      for transfer in transfers {
        guard
          let worktreeID = repositories.first(where: { $0.id == transfer.repositoryID })?
            .worktrees.first(where: { $0.name == transfer.worktreeName })?.id
        else { continue }
        sidebar.mergeCustomization(
          title: transfer.customization.title,
          color: transfer.customization.color,
          worktree: worktreeID,
          in: transfer.repositoryID
        )
      }
    }
  }

  private func applyRepositories(
    _ repositories: [Repository],
    roots: [URL],
    shouldPruneArchivedWorktreeIDs: Bool,
    state: inout State,
    animated: Bool
  ) -> ApplyRepositoriesResult {
    let repositoryIDs = Set(repositories.map(\.id))
    let (filteredPendingWorktrees, customizationTransfers) =
      prunedPendingWorktrees(state: state, repositories: repositories, repositoryIDs: repositoryIDs)
    seedCustomizationForDiscoveredWorktree(
      transfers: customizationTransfers,
      repositories: repositories,
      state: &state,
    )
    let availableWorktreeIDs = Set(repositories.flatMap { $0.worktrees.map(\.id) })
    let (filteredRemovingRepositoryIDs, filteredActiveRemovalBatches) =
      prunedRemovalTrackers(state: state, availableRepoIDs: repositoryIDs)
    let identifiedRepositories = IdentifiedArray(uniqueElements: repositories)
    if animated {
      withAnimation {
        state.repositories = identifiedRepositories
        state.pendingWorktrees = filteredPendingWorktrees
        state.removingRepositoryIDs = filteredRemovingRepositoryIDs
        state.activeRemovalBatches = filteredActiveRemovalBatches
      }
    } else {
      state.repositories = identifiedRepositories
      state.pendingWorktrees = filteredPendingWorktrees
      state.removingRepositoryIDs = filteredRemovingRepositoryIDs
      state.activeRemovalBatches = filteredActiveRemovalBatches
    }
    // Reconcile unconditionally so the seed invariant ("every live
    // non-main worktree has a bucket") holds after partial-failure
    // loads too — gating this on `failures.isEmpty` would skip the
    // seed pass whenever any root failed to resolve and leave
    // `sidebar.sections` empty for the healthy repos, which breaks
    // the view. Cross-repo archive loss on transient roster misses
    // is already guarded by the orphan-preservation pass inside
    // `reconcileSidebarState`, which copies `.archived` + `.pinned`
    // forward for any repo that drops out of `availableRepoIDs`.
    //
    // Gate the `.pinned` / `.unpinned` liveness prune on the initial
    // load: on the very first `.repositoriesLoaded` tick,
    // `Repository.worktrees` hydration can race with the
    // migrator-written IDs in `sidebar.json`, so a transient roster
    // view may not yet contain every curated worktree. Skipping the
    // destructive drop until the second load lets migrated curation
    // survive that transient view. The seed pass and the
    // orphan-preservation pass still run on the first load, so newly
    // discovered worktrees still land in `.unpinned` and vanished
    // repos still get tombstoned.
    state.reconcileSidebarState(roots: roots, pruneLivenessAgainstRoster: state.isInitialLoadComplete)
    Self.syncSidebar(&state)
    let didPruneArchivedWorktreeIDs =
      shouldPruneArchivedWorktreeIDs
      ? state.pruneArchivedWorktreeIDs(availableWorktreeIDs: availableWorktreeIDs)
      : false
    if !state.isShowingArchivedWorktrees, !state.isSelectionValid(state.selectedWorktreeID) {
      state.selection = nil
    }
    if state.shouldRestoreLastFocusedWorktree {
      state.shouldRestoreLastFocusedWorktree = false
      if state.selection == nil, state.isSelectionValid(state.sidebar.focusedWorktreeID) {
        state.selection = state.sidebar.focusedWorktreeID.map(SidebarSelection.worktree)
      }
    }
    if state.selection == nil, state.shouldSelectFirstAfterReload {
      state.selection = state.firstAvailableWorktreeID(from: repositories)
        .map(SidebarSelection.worktree)
      state.shouldSelectFirstAfterReload = false
    }
    return ApplyRepositoriesResult(didPruneArchivedWorktreeIDs: didPruneArchivedWorktreeIDs)
  }

  /// Symmetric prune for the repo-level removal trackers — every
  /// other tracker in `applyRepositories` is intersected against
  /// the live roster; leaving these two alone would let a
  /// mid-flight removal dangle if a concurrent reload drops the
  /// owning repo before the detached trash/unlink effect reports
  /// completion. The prune is silent: orphan-completion handlers
  /// in `.repositoryRemovalCompleted` already tolerate missing
  /// records, and a `reportIssue` here would fire on legitimate
  /// reload-during-removal flows (especially the synchronous
  /// `.gitRepositoryUnlink` path). The symmetry itself is the
  /// win — a future regression that leaves real garbage here
  /// would now be cleared on the next reload instead of
  /// silently piling up.
  private func prunedRemovalTrackers(
    state: State,
    availableRepoIDs: Set<Repository.ID>
  ) -> (
    removingRepositoryIDs: [Repository.ID: RepositoryRemovalRecord],
    activeRemovalBatches: [BatchID: ActiveRemovalBatch]
  ) {
    var removing = state.removingRepositoryIDs
    var batches = state.activeRemovalBatches
    for droppedID in removing.keys where !availableRepoIDs.contains(droppedID) {
      removing[droppedID] = nil
    }
    for (batchID, batch) in batches {
      let surviving = batch.pending.intersection(availableRepoIDs)
      guard surviving.count != batch.pending.count else { continue }
      if surviving.isEmpty, batch.succeeded.isEmpty {
        batches[batchID] = nil
      } else {
        var pruned = batch
        pruned.pending = surviving
        for droppedID in batch.pending.subtracting(surviving) {
          pruned.failureMessagesByRepositoryID[droppedID] = nil
        }
        batches[batchID] = pruned
      }
    }
    return (removing, batches)
  }

  private func blockingScriptFailureAlert(
    kind: BlockingScriptKind,
    exitCode: Int,
    worktreeID: Worktree.ID,
    tabId: TerminalTabID?,
    state: State
  ) -> AlertState<Alert> {
    let worktreeName = state.worktree(for: worktreeID)?.name
    let repoName = state.repositoryID(containing: worktreeID)
      .flatMap { state.repositories[id: $0]?.name }
    let parts = [repoName, worktreeName].compactMap(\.self)
    if parts.isEmpty {
      repositoriesLogger.debug("blockingScriptFailureAlert: worktree \(worktreeID) not found in state")
    }
    let subtitle = parts.isEmpty ? "Unknown worktree" : parts.joined(separator: " — ")
    return AlertState {
      TextState("\(kind.tabTitle) failed")
    } actions: {
      if let tabId {
        ButtonState(action: .viewTerminalTab(worktreeID, tabId: tabId)) {
          TextState("View Terminal")
        }
      }
      ButtonState(role: .cancel) {
        TextState("Dismiss")
      }
    } message: {
      TextState("\(subtitle)\n\n\(blockingScriptExitMessage(exitCode))")
    }
  }

}

extension RepositoriesFeature.State {
  var selectedWorktreeID: Worktree.ID? {
    selection?.worktreeID
  }

  /// Builds the `sidebarSelectionSlice` cache. Reads `sidebarItems[id:]` per
  /// selected row, so it belongs to the reducer: calling it from a view body
  /// would observation-track every row's properties.
  func computeSidebarSelectionSlice() -> SidebarSelectionSlice {
    let rows = effectiveSidebarSelectedRows()
    return SidebarSelectionSlice(
      rows: rows,
      archiveTargets:
        rows
        .filter { $0.lifecycle == .idle && !$0.isMainWorktree }
        .map { RepositoriesFeature.ArchiveWorktreeTarget(worktreeID: $0.id, repositoryID: $0.repositoryID) },
      deleteTargets:
        rows
        .filter { $0.lifecycle == .idle }
        .map { RepositoriesFeature.DeleteWorktreeTarget(worktreeID: $0.id, repositoryID: $0.repositoryID) },
      hasMixedKindSelection: rows.count > 1 && Set(rows.map(\.kind)).count > 1,
      isAllFoldersBulk: rows.count > 1 && rows.allSatisfy(\.isFolder)
    )
  }

  /// The multi-selection in sidebar order, falling back to the focused row.
  private func effectiveSidebarSelectedRows() -> [SidebarContextRow] {
    var rows: [SidebarContextRow] = []
    var seen: Set<Worktree.ID> = []
    for row in orderedSidebarItems() where sidebarSelectedWorktreeIDs.contains(row.id) {
      rows.append(SidebarContextRow(row))
      seen.insert(row.id)
    }
    // Archived rows sit outside the pinned / unpinned buckets the ordered walk
    // covers, so a selected row that's back on screen for its delete script is
    // only reachable through `selectedRow(for:)`.
    if seen.count < sidebarSelectedWorktreeIDs.count {
      for id in sidebarItems.ids where sidebarSelectedWorktreeIDs.contains(id) && !seen.contains(id) {
        guard let row = selectedRow(for: id) else { continue }
        rows.append(SidebarContextRow(row))
      }
    }
    guard rows.isEmpty else { return rows }
    return selectedRow(for: selectedWorktreeID).map { [SidebarContextRow($0)] } ?? []
  }

  var expandedRepositoryIDs: Set<Repository.ID> {
    let repositoryIDs = Set(repositories.map(\.id))
    let collapsedSet: Set<Repository.ID> = Set(
      sidebar.sections.compactMap { $0.value.collapsed ? $0.key : nil }
    ).intersection(repositoryIDs)
    let pendingRepositoryIDs = Set(pendingWorktrees.map(\.repositoryID))
    return repositoryIDs.subtracting(collapsedSet).union(pendingRepositoryIDs)
  }

  func isRepositoryExpanded(_ repositoryID: Repository.ID) -> Bool {
    expandedRepositoryIDs.contains(repositoryID)
  }

  // Menu/UI enablement for ⌘⌃← / ⌘⌃→. Raw `!isEmpty` lies whenever
  // the back/forward stack contains only stale ids (worktrees
  // archived/deleted between visits) or a self-referential entry
  // equal to the current selection — both get drained silently by
  // `navigateWorktreeHistory`. Filtering at read-time keeps the
  // navigator's lazy-prune contract honest for the menu.
  var canNavigateWorktreeHistoryBackward: Bool {
    canNavigate(stack: worktreeHistoryBackStack)
  }

  var canNavigateWorktreeHistoryForward: Bool {
    canNavigate(stack: worktreeHistoryForwardStack)
  }

  private func canNavigate(stack: [Worktree.ID]) -> Bool {
    let current = selectedWorktreeID
    return stack.contains { id in
      id != current && worktreeExists(id)
    }
  }

  var sidebarSelections: Set<SidebarSelection> {
    guard !isShowingArchivedWorktrees else {
      return [.archivedWorktrees]
    }
    if case .failedRepository(let id) = selection {
      return [.failedRepository(id)]
    }
    var selections = Set(sidebarSelectedWorktreeIDs.map(SidebarSelection.worktree))
    if let selectedWorktreeID {
      selections.insert(.worktree(selectedWorktreeID))
    }
    return selections
  }

  var selectedFailedRepositoryID: Repository.ID? {
    selection?.failedRepositoryID
  }

  func worktreeID(byOffset offset: Int) -> Worktree.ID? {
    // Walk the structure's `hotkeySlots`, which already reflects the
    // visible top-down order (hoisted Pinned + Active first, then per-repo
    // with hoisted rows filtered out, with the nest-by-branch alphabetical
    // sort applied). Arrow navigation, ⌃1..⌃0 hotkeys, and the menu-bar
    // slot picker all bind to the same visual ordering. The post-reduce
    // hook keeps the cache fresh for every structure-affecting action,
    // including in tests, so reading the cache here is always live.
    let ids = sidebarStructure.hotkeySlots.map(\.id)
    guard !ids.isEmpty else { return nil }
    if let currentID = selectedWorktreeID, let currentIndex = ids.firstIndex(of: currentID) {
      return ids[(currentIndex + offset + ids.count) % ids.count]
    }
    // Selection hidden behind a collapsed group: land on the nearest visible
    // neighbor in the direction of travel rather than jumping top / bottom.
    // The unfiltered anchor list intentionally walks the per-repo bucket
    // order (collapsed groups expanded) since hoisted rows are always
    // visible and therefore never fall through to this branch.
    if let currentID = selectedWorktreeID,
      let anchor = hiddenSelectionAnchor(currentID: currentID, visibleIDs: ids),
      let neighbor = nearestVisibleNeighbor(
        from: anchor.index, in: anchor.allIDs, visibleSet: Set(ids), forward: offset > 0
      )
    {
      return neighbor
    }
    return ids[offset > 0 ? 0 : ids.count - 1]
  }

  /// Locate `currentID` inside the unfiltered ordered list when it's not in
  /// `visibleIDs` (i.e. hidden behind a collapsed group). Returns both the
  /// index and the unfiltered list so the caller doesn't have to recompute
  /// it on the cold arrow-nav path.
  private func hiddenSelectionAnchor(
    currentID: Worktree.ID,
    visibleIDs: [Worktree.ID]
  ) -> (index: Int, allIDs: [Worktree.ID])? {
    guard !visibleIDs.contains(currentID) else { return nil }
    let allIDs = orderedSidebarItemIDs(
      includingRepositoryIDs: expandedRepositoryIDs,
      ignoreCollapsedGroups: true
    )
    guard let index = allIDs.firstIndex(of: currentID) else { return nil }
    return (index, allIDs)
  }

  private func nearestVisibleNeighbor(
    from anchor: Int,
    in allIDs: [Worktree.ID],
    visibleSet: Set<Worktree.ID>,
    forward: Bool
  ) -> Worktree.ID? {
    let stride = forward ? 1 : -1
    var index = anchor + stride
    while index >= 0, index < allIDs.count {
      if visibleSet.contains(allIDs[index]) { return allIDs[index] }
      index += stride
    }
    // Nothing in the requested direction: wrap to the opposite end of the
    // visible list so arrow nav still moves.
    return forward ? allIDs.first(where: visibleSet.contains) : allIDs.last(where: visibleSet.contains)
  }

  var isShowingArchivedWorktrees: Bool {
    selection == .archivedWorktrees
  }

  var archivedWorktreeIDs: [Worktree.ID] {
    sidebar.archivedWorktrees.map(\.worktreeID)
  }

  var archivedWorktreeIDSet: Set<Worktree.ID> {
    var set: Set<Worktree.ID> = []
    for section in sidebar.sections.values {
      guard let archived = section.buckets[.archived] else { continue }
      for worktreeID in archived.items.keys {
        set.insert(worktreeID)
      }
    }
    return set
  }

  func isWorktreeArchived(_ id: Worktree.ID) -> Bool {
    guard let repositoryID = repositoryID(containing: id) else {
      return false
    }
    return sidebar.sections[repositoryID]?.buckets[.archived]?.items[id] != nil
  }

  /// Archived rows show no running-script dots, except while their delete script
  /// runs (the row re-enters the sidebar to show that terminal).
  func stripsArchivedRunningScripts(for id: Worktree.ID, lifecycle: SidebarItemFeature.State.Lifecycle) -> Bool {
    isWorktreeArchived(id) && lifecycle != .deletingScript
  }

  func worktreesForInfoWatcher() -> [Worktree] {
    // Folder repos lack a `.git` to observe, and orphan rows have no
    // working dir at all; skip both so the watcher doesn't probe paths
    // that can't service its queries.
    let worktrees =
      repositories
      .filter(\.isGitRepository)
      .flatMap(\.worktrees)
      .filter { !$0.isMissing }
    guard !isShowingArchivedWorktrees else {
      return worktrees
    }
    let archivedSet = archivedWorktreeIDSet
    return worktrees.filter { !archivedSet.contains($0.id) }
  }

  func archivedWorktreesByRepository() -> [(repository: Repository, worktrees: [Worktree])] {
    let archivedSet = archivedWorktreeIDSet
    var groups: [(repository: Repository, worktrees: [Worktree])] = []
    for repository in repositories {
      let worktrees = Array(repository.worktrees.filter { archivedSet.contains($0.id) })
      if !worktrees.isEmpty {
        groups.append((repository: repository, worktrees: worktrees))
      }
    }
    return groups
  }

  var canCreateWorktree: Bool {
    if repositories.isEmpty {
      return false
    }
    if let repository = repositoryForWorktreeCreation {
      return removingRepositoryIDs[repository.id] == nil
    }
    return false
  }

  func worktree(for id: Worktree.ID?) -> Worktree? {
    guard let id else { return nil }
    for repository in repositories {
      if let worktree = repository.worktrees[id: id] {
        return worktree
      }
    }
    return nil
  }

  /// Tint colors for scripts currently running in the given worktree,
  /// ordered deterministically by script ID. Snapshotted at run-time so a
  /// live color edit only takes effect on the next run; this also keeps
  /// the dot rendering when a script is deleted mid-run.
  func runningScriptColors(for worktreeID: Worktree.ID) -> [RepositoryColor] {
    guard let scripts = sidebarItems[id: worktreeID]?.runningScripts else { return [] }
    return scripts.sorted(by: { $0.id < $1.id }).map(\.tint)
  }

  func pendingWorktree(for id: Worktree.ID?) -> PendingWorktree? {
    guard let id else { return nil }
    return pendingWorktrees.first(where: { $0.id == id })
  }

  /// Valid sidebar-selection targets: live worktrees plus still-creating pending entries.
  var selectableWorktreeIDs: Set<Worktree.ID> {
    var ids = Set(repositories.flatMap { $0.worktrees.map(\.id) })
    for pending in pendingWorktrees {
      ids.insert(pending.id)
    }
    return ids
  }

  func shouldFocusTerminal(for worktreeID: Worktree.ID) -> Bool {
    sidebarItems[id: worktreeID]?.shouldFocusTerminal == true
  }

  func selectedRow(for id: Worktree.ID?) -> SidebarItemFeature.State? {
    guard let id else { return nil }
    // Archived worktrees have no detail row except while their delete script
    // runs, when the row re-enters the sidebar and must show its terminal.
    if isWorktreeArchived(id), sidebarItems[id: id]?.lifecycle != .deletingScript { return nil }
    return sidebarItems[id: id]
  }

  func repositoryName(for id: Repository.ID) -> String? {
    repositories[id: id]?.name
  }

  func orderedRepositoryRoots() -> [URL] {
    let rootsByID = Dictionary(
      uniqueKeysWithValues: repositoryRoots.map {
        (RepositoryID($0.standardizedFileURL.path(percentEncoded: false)), $0.standardizedFileURL)
      }
    )
    var ordered: [URL] = []
    var seen: Set<Repository.ID> = []
    for id in sidebar.sections.keys {
      if let rootURL = rootsByID[id], seen.insert(id).inserted {
        ordered.append(rootURL)
      }
    }
    for rootURL in repositoryRoots {
      let id = RepositoryID(rootURL.standardizedFileURL.path(percentEncoded: false))
      if seen.insert(id).inserted {
        ordered.append(rootURL.standardizedFileURL)
      }
    }
    if ordered.isEmpty {
      // Local only: a remote repo's `rootURL` is a remote path whose `.path`
      // doesn't match its `remote:` id, so it must not leak in as a bogus id.
      ordered = repositories.filter { $0.host == nil }.map(\.rootURL)
    }
    return ordered
  }

  /// Every repository id in sidebar order. The persisted `sidebar.sections`
  /// order wins, so a drag sticks across recompute and reload; anything not yet
  /// placed falls back to load order. Local roots and host-keyed remote ids are
  /// treated alike: remote ids aren't in `repositoryRoots`, so the
  /// `repositories` pass is what surfaces them.
  func orderedRepositoryIDs() -> [Repository.ID] {
    let rootIDs = repositoryRoots.map {
      RepositoryID($0.standardizedFileURL.path(percentEncoded: false))
    }
    var ordered: [Repository.ID] = []
    var seen: Set<Repository.ID> = []
    for id in sidebar.sections.keys where repositories[id: id] != nil || rootIDs.contains(id) {
      if seen.insert(id).inserted { ordered.append(id) }
    }
    for id in rootIDs where seen.insert(id).inserted { ordered.append(id) }
    for repository in repositories where seen.insert(repository.id).inserted {
      ordered.append(repository.id)
    }
    return ordered
  }

  func repositoryID(for worktreeID: Worktree.ID?) -> Repository.ID? {
    selectedRow(for: worktreeID)?.repositoryID
  }

  func repositoryID(containing worktreeID: Worktree.ID) -> Repository.ID? {
    for repository in repositories where repository.worktrees[id: worktreeID] != nil {
      return repository.id
    }
    return nil
  }

  /// Answers for the repositories the disk pass has not reached yet, from what is already
  /// in memory: the settings file's entry for that repository, then the default editor.
  /// Only the repository's own `supacode.json` needs the disk, so that is all the effect
  /// is left with, and no consumer has to invent an answer for a repository with no entry.
  mutating func seedUnresolvedOpenActions() {
    // With no installed set, the default editor normalizes away and every repository that
    // overrides nothing folds to `preferredDefault([])`, a guess the sweep overwrites a
    // moment later. The sweep is synchronous before the first frame, so this is empty
    // only where nothing has resolved anything yet.
    guard !installedOpenActions.isEmpty else { return }
    let unresolved = repositories.filter { openActionByRepositoryID[$0.id] == nil }
    guard !unresolved.isEmpty else { return }
    @Shared(.settingsFile) var settingsFile
    let defaultEditorID = settingsFile.global.defaultEditorID
    for repository in unresolved {
      // The settings file is keyed the way `RepositorySettingsKey` keys it, which is not
      // `Repository.ID` (that one keeps its trailing slash, and remote keys are branded).
      let key = RepositorySettingsKey(rootURL: repository.rootURL, host: repository.host)
      openActionByRepositoryID[repository.id] = OpenWorktreeAction.fromSettingsID(
        settingsFile.repositories[key.repositoryID]?.openActionID,
        defaultEditorID: defaultEditorID,
        installed: installedOpenActions
      )
    }
  }

  /// Selectability check (archived = no, pending = yes) used by the worktree-history
  /// navigator and its menu-enablement filter when only a yes / no is needed.
  func worktreeExists(_ worktreeID: Worktree.ID) -> Bool {
    // A delete-script archived row is surfaced back into the sidebar and stays a
    // valid selection so a roster reload can't evict the user off its live
    // terminal mid-run (mirrors `selectedRow`).
    if isWorktreeArchived(worktreeID) {
      return sidebarItems[id: worktreeID]?.lifecycle == .deletingScript
    }
    if pendingWorktree(for: worktreeID) != nil { return true }
    return repositories.contains { $0.worktrees[id: worktreeID] != nil }
  }

  func isMainWorktree(_ worktree: Worktree) -> Bool {
    worktree.workingDirectory.standardizedFileURL == worktree.repositoryRootURL.standardizedFileURL
  }

  func isWorktreeMerged(_ worktree: Worktree) -> Bool {
    sidebarItems[id: worktree.id]?.pullRequest?.state == "MERGED"
  }

  func orderedPinnedWorktreeIDs(in repository: Repository) -> [Worktree.ID] {
    let mainID = repository.worktrees.first(where: { isMainWorktree($0) })?.id
    let availableIDs = Set(repository.worktrees.map(\.id))
    let pinnedKeys = sidebar.sections[repository.id]?.buckets[.pinned]?.items.keys ?? []
    return pinnedKeys.filter { id in
      id != mainID && availableIDs.contains(id)
    }
  }

  func orderedPinnedWorktrees(in repository: Repository) -> [Worktree] {
    orderedPinnedWorktreeIDs(in: repository).compactMap { repository.worktrees[id: $0] }
  }

  func orderedUnpinnedWorktreeIDs(in repository: Repository) -> [Worktree.ID] {
    let mainID = repository.worktrees.first(where: { isMainWorktree($0) })?.id
    let section = sidebar.sections[repository.id]
    let pinnedKeys = Set(section?.buckets[.pinned]?.items.keys ?? [])
    let archivedKeys = Set(section?.buckets[.archived]?.items.keys ?? [])
    let available = repository.worktrees.filter { worktree in
      worktree.id != mainID
        && !pinnedKeys.contains(worktree.id)
        && !archivedKeys.contains(worktree.id)
    }
    let availableIDs = Set(available.map(\.id))
    let orderedKeys = section?.buckets[.unpinned]?.items.keys ?? []
    let orderedIDSet = Set(orderedKeys)
    var seen: Set<Worktree.ID> = []
    var missing: [Worktree.ID] = []
    for worktree in available where !orderedIDSet.contains(worktree.id) {
      if seen.insert(worktree.id).inserted {
        missing.append(worktree.id)
      }
    }
    var ordered: [Worktree.ID] = []
    for id in orderedKeys {
      if availableIDs.contains(id),
        seen.insert(id).inserted
      {
        ordered.append(id)
      }
    }
    return missing + ordered
  }

  func orderedUnpinnedWorktrees(in repository: Repository) -> [Worktree] {
    orderedUnpinnedWorktreeIDs(in: repository).compactMap { repository.worktrees[id: $0] }
  }

  func orderedWorktrees(in repository: Repository) -> [Worktree] {
    var ordered: [Worktree] = []
    if let mainWorktree = repository.worktrees.first(where: { isMainWorktree($0) }) {
      if !isWorktreeArchived(mainWorktree.id) {
        ordered.append(mainWorktree)
      }
    }
    ordered.append(contentsOf: orderedPinnedWorktrees(in: repository))
    ordered.append(contentsOf: orderedUnpinnedWorktrees(in: repository))
    return ordered
  }

  func isWorktreePinned(_ worktree: Worktree) -> Bool {
    guard let owningRepositoryID = repositoryID(containing: worktree.id) else {
      return false
    }
    return sidebar.sections[owningRepositoryID]?.buckets[.pinned]?.items[worktree.id] != nil
  }

  var confirmWorktreeAlert: RepositoriesFeature.Alert? {
    guard let alert else { return nil }
    for button in alert.buttons {
      if case .confirmArchiveWorktree(let worktreeID, let repositoryID)? = button.action.action {
        return .confirmArchiveWorktree(worktreeID, repositoryID)
      }
      if case .confirmArchiveWorktrees(let targets)? = button.action.action {
        return .confirmArchiveWorktrees(targets)
      }
      if case .confirmDeleteSidebarItems(let targets, let disposition)? = button.action.action {
        return .confirmDeleteSidebarItems(targets, disposition: disposition)
      }
      if case .confirmRemoveFailedRepository(let repositoryID)? = button.action.action {
        return .confirmRemoveFailedRepository(repositoryID)
      }
    }
    return nil
  }

  func isRemovingRepository(_ repository: Repository) -> Bool {
    guard removingRepositoryIDs[repository.id] != nil else { return false }
    // While a folder's delete script is running, don't treat the
    // repo as "removing" — the sidebar row must stay clickable so
    // the user can view the script terminal and, on failure, retry
    // or cancel.
    let folderWorktreeID = Repository.folderWorktreeID(for: repository.rootURL)
    if !repository.isGitRepository,
      sidebarItems[id: folderWorktreeID]?.lifecycle == .deletingScript
    {
      return false
    }
    return true
  }

  func orderedSidebarItems() -> [SidebarItemFeature.State] {
    orderedSidebarItems(includingRepositoryIDs: Set(repositories.map(\.id)))
  }

  /// Reads `sidebarItems[id:]` per row, so callers observation-track every row's properties.
  /// Use `orderedSidebarItemIDs(includingRepositoryIDs:)` on the sidebar render path.
  ///
  /// Walks the raw custom drag order (pinned + unpinned) without applying the
  /// branch-nesting trie or skipping rows hidden inside collapsed groups.
  /// `orderedSidebarItemIDs` diverges from this when nesting is on: that one
  /// matches the visible alphabetical order the sidebar / hotkeys see, this
  /// one feeds command-palette / multi-select consumers that intentionally
  /// surface every row in the curated order regardless of UI collapse state.
  func orderedSidebarItems(includingRepositoryIDs: Set<Repository.ID>) -> [SidebarItemFeature.State] {
    var rows: [SidebarItemFeature.State] = []
    for repositoryID in orderedRepositoryIDs() where includingRepositoryIDs.contains(repositoryID) {
      guard let bucket = sidebarGrouping.bucketsByRepository[repositoryID] else { continue }
      for rowID in bucket[.pinned] {
        if let item = sidebarItems[id: rowID] { rows.append(item) }
      }
      for rowID in bucket[.unpinned] {
        if let item = sidebarItems[id: rowID] { rows.append(item) }
      }
    }
    return rows
  }

  /// Visible-row order that drives hotkey assignment + arrow navigation.
  /// Matches what the sidebar actually renders: main worktree first (when
  /// pinned), then pinned-tail, then pending, then unpinned-tail. When
  /// branch nesting is on for a git repo, the pinned-tail and unpinned-tail
  /// runs are filtered through `SidebarBranchNesting.buildRows` so the
  /// order is alphabetical and rows inside collapsed groups are skipped.
  ///
  /// Pass `ignoreCollapsedGroups: true` to get the same ordering but include
  /// rows hidden inside collapsed groups. Used by arrow navigation to anchor
  /// off a currently-hidden selection so the next step lands on the nearest
  /// visible neighbor instead of jumping to the top / bottom of the list.
  ///
  /// Diverges from the heavy `orderedSidebarItems(includingRepositoryIDs:)`
  /// flavor, which still walks the raw drag order. Heavy flavor feeds
  /// command-palette / multi-select consumers that have their own ordering
  /// intent; don't unify the two without auditing those call sites.
  func orderedSidebarItemIDs(
    includingRepositoryIDs: Set<Repository.ID>,
    ignoreCollapsedGroups: Bool = false
  ) -> [Worktree.ID] {
    var ids: [Worktree.ID] = []
    for repositoryID in orderedRepositoryIDs() where includingRepositoryIDs.contains(repositoryID) {
      guard let bucket = sidebarGrouping.bucketsByRepository[repositoryID] else { continue }
      let pinnedRows = bucket[.pinned]
      let unpinnedRows = bucket[.unpinned]
      let pendingIDs = Set(pendingWorktrees.filter { $0.repositoryID == repositoryID }.map(\.id))
      let mainID: SidebarItemID? = pinnedRows.first.flatMap {
        sidebarItems[id: $0]?.isMainWorktree == true ? $0 : nil
      }
      let pinnedTail = pinnedRows.filter { $0 != mainID }
      let pendingTail = unpinnedRows.filter { pendingIDs.contains($0) }
      let unpinnedTail = unpinnedRows.filter { !pendingIDs.contains($0) }
      let isGit = repositories[id: repositoryID]?.isGitRepository == true
      let useNesting = sidebarNestWorktreesByBranch && isGit

      if let mainID { ids.append(mainID) }
      ids.append(
        contentsOf: branchNestingRowIDs(
          rowIDs: pinnedTail,
          repositoryID: repositoryID,
          bucket: .pinned,
          useNesting: useNesting,
          ignoreCollapsedGroups: ignoreCollapsedGroups
        )
      )
      ids.append(contentsOf: pendingTail)
      ids.append(
        contentsOf: branchNestingRowIDs(
          rowIDs: unpinnedTail,
          repositoryID: repositoryID,
          bucket: .unpinned,
          useNesting: useNesting,
          ignoreCollapsedGroups: ignoreCollapsedGroups
        )
      )
    }
    return ids
  }

  /// Projection through `SidebarBranchNesting.buildRows` that drops headers
  /// and (when `ignoreCollapsedGroups == false`) any leaf hidden inside a
  /// collapsed group; falls back to the raw custom-drag order when nesting
  /// is off.
  private func branchNestingRowIDs(
    rowIDs: [SidebarItemID],
    repositoryID: Repository.ID,
    bucket: SidebarBucket,
    useNesting: Bool,
    ignoreCollapsedGroups: Bool
  ) -> [SidebarItemID] {
    guard useNesting, !rowIDs.isEmpty else { return rowIDs }
    let collapsedPrefixes: Set<String> =
      ignoreCollapsedGroups
      ? []
      : sidebar.sections[repositoryID]?.buckets[bucket]?.collapsedBranchPrefixes ?? []
    // `uniquingKeysWith` so a transient duplicate row ID can't crash the hotkey path.
    let branchNames = Dictionary(
      rowIDs.compactMap { id -> (SidebarItemID, String)? in
        sidebarItems[id: id].map { (id, $0.branchName) }
      },
      uniquingKeysWith: { first, _ in first }
    )
    let rows = SidebarBranchNesting.buildRows(
      itemIDs: rowIDs,
      branchNames: branchNames,
      collapsedPrefixes: collapsedPrefixes
    )
    return rows.compactMap { row in
      if case .leaf(let id, _, _) = row { return id }
      return nil
    }
  }

  func hotkeyWorktreeSlots() -> [HotkeyWorktreeSlot] {
    hotkeyWorktreeSlots(includingRepositoryIDs: Set(repositories.map(\.id)))
  }

  /// Menu-bar projection: reads only `name` and `repositoryID` per row, both stable
  /// across PR / lifecycle ticks. Lets `focusedSceneValue` dedupe so open submenus
  /// don't rebuild and drop hover.
  func hotkeyWorktreeSlots(includingRepositoryIDs: Set<Repository.ID>) -> [HotkeyWorktreeSlot] {
    hotkeyWorktreeSlots(
      for: orderedSidebarItemIDs(includingRepositoryIDs: includingRepositoryIDs)
    )
  }

  /// Project a caller-provided ID list into menu slots. Used when the sidebar
  /// has composed an order the reducer can't derive on its own (e.g. highlight
  /// sections hoisted above per-repo rows).
  func hotkeyWorktreeSlots(for ids: [Worktree.ID]) -> [HotkeyWorktreeSlot] {
    let nameByRepoID = Dictionary(uniqueKeysWithValues: repositories.map { ($0.id, $0.name) })
    return ids.compactMap { id in
      guard let item = sidebarItems[id: id] else { return nil }
      let repositoryName = Repository.sidebarDisplayName(
        custom: sidebar.sections[item.repositoryID]?.title,
        fallback: nameByRepoID[item.repositoryID] ?? ""
      )
      return HotkeyWorktreeSlot(
        id: item.id,
        name: SidebarDisplayName.resolved(custom: item.customTitle, fallback: item.name) ?? item.name,
        repositoryID: item.repositoryID,
        repositoryName: repositoryName
      )
    }
  }
}

// MARK: - Mutation helpers on State.

struct FailedWorktreeCleanup {
  let didRemoveWorktree: Bool
  let worktree: Worktree?
}

extension RepositoriesFeature.State {
  mutating func removePendingWorktree(_ id: Worktree.ID) {
    guard pendingWorktrees.contains(where: { $0.id == id }) else { return }
    pendingWorktrees.removeAll { $0.id == id }
    RepositoriesFeature.syncSidebar(&self)
  }

  /// Single source of truth for draining the in-flight customization parked by the New Worktree
  /// prompt's `submit` delegate. `branchName == nil` drains every entry for the repo (used by the
  /// removing-repo guard and prompt cancel); a non-nil `branchName` drains just that (repo, branch)
  /// pair so concurrent creations don't lose unrelated customizations.
  mutating func dropPendingCustomization(repositoryID: Repository.ID, branchName: String? = nil) {
    if let branchName {
      pendingCreationCustomizations[repositoryID]?.removeValue(forKey: branchName)
    } else {
      pendingCreationCustomizations.removeValue(forKey: repositoryID)
    }
    if pendingCreationCustomizations[repositoryID]?.isEmpty == true {
      pendingCreationCustomizations.removeValue(forKey: repositoryID)
    }
  }

  @discardableResult
  mutating func updatePendingWorktreeProgress(
    _ id: Worktree.ID,
    progress: WorktreeCreationProgress
  ) -> Bool {
    guard let index = pendingWorktrees.firstIndex(where: { $0.id == id }) else { return false }
    pendingWorktrees[index].progress = progress
    return true
  }

  mutating func insertWorktree(_ worktree: Worktree, repositoryID: Repository.ID) {
    guard let index = repositories.index(id: repositoryID) else { return }
    let repository = repositories[index]
    if repository.worktrees[id: worktree.id] != nil { return }
    var worktrees = repository.worktrees
    worktrees.insert(worktree, at: 0)
    repositories[index] = repository.withWorktrees(worktrees)
  }

  @discardableResult
  mutating func removeWorktree(_ worktreeID: Worktree.ID, repositoryID: Repository.ID) -> Bool {
    guard let index = repositories.index(id: repositoryID) else { return false }
    let repository = repositories[index]
    guard repository.worktrees[id: worktreeID] != nil else { return false }
    var worktrees = repository.worktrees
    worktrees.remove(id: worktreeID)
    repositories[index] = repository.withWorktrees(worktrees)
    // Prune the MRU here so every removal path (delete, archive, failed cleanup)
    // drops it. `Worktree.ID` is a reusable path, so a stale entry would re-rank
    // a freshly created worktree at the same path as recently used.
    worktreeMRU.removeAll { $0 == worktreeID }
    return true
  }

  mutating func cleanupFailedWorktree(
    repositoryID: Repository.ID,
    name: String?,
    baseDirectory: URL,
  ) -> FailedWorktreeCleanup {
    guard let name, !name.isEmpty else {
      return FailedWorktreeCleanup(didRemoveWorktree: false, worktree: nil)
    }
    let repositoryRootURL = URL(fileURLWithPath: repositoryID.rawValue).standardizedFileURL
    let normalizedBaseDirectory = baseDirectory.standardizedFileURL
    let worktreeURL =
      normalizedBaseDirectory
      .appending(path: name, directoryHint: .isDirectory)
      .standardizedFileURL
    guard worktreeURL.isInside(baseDirectory: normalizedBaseDirectory) else {
      return FailedWorktreeCleanup(didRemoveWorktree: false, worktree: nil)
    }
    let worktreeID = WorktreeID(worktreeURL.path(percentEncoded: false))
    let worktree =
      repositories[id: repositoryID]?.worktrees[id: worktreeID]
      ?? Worktree(
        id: worktreeID,
        kind: .git,
        name: name,
        detail: "",
        workingDirectory: worktreeURL,
        repositoryRootURL: repositoryRootURL,
      )
    let didRemoveWorktree = cleanupWorktreeState(worktreeID, repositoryID: repositoryID)
    return FailedWorktreeCleanup(didRemoveWorktree: didRemoveWorktree, worktree: worktree)
  }

  @discardableResult
  mutating func cleanupWorktreeState(
    _ worktreeID: Worktree.ID,
    repositoryID: Repository.ID
  ) -> Bool {
    let didRemoveWorktree = removeWorktree(worktreeID, repositoryID: repositoryID)
    pendingWorktrees.removeAll { $0.id == worktreeID }
    // Drop the worktree from every bucket in its section. The worktree is going
    // away entirely so the current bucket doesn't matter.
    _ = $sidebar.withLock { sidebar in
      sidebar.removeAnywhere(worktree: worktreeID, in: repositoryID)
    }
    RepositoriesFeature.syncSidebar(&self)
    return didRemoveWorktree
  }

  /// Effect that clears a folder worktree row's lifecycle if it's still
  /// mid-delete. Folder removals run a one-row delete-script pipeline and
  /// never use the per-worktree git-delete codepath.
  func clearFolderRowLifecycleEffect(_ worktreeID: Worktree.ID) -> Effect<RepositoriesFeature.Action> {
    guard let lifecycle = sidebarItems[id: worktreeID]?.lifecycle else { return .none }
    guard lifecycle == .deleting || lifecycle == .deletingScript else { return .none }
    return .send(.sidebarItems(.element(id: worktreeID, action: .lifecycleChanged(.idle))))
  }
}

extension URL {
  fileprivate func isInside(baseDirectory: URL) -> Bool {
    let normalizedPath = standardizedFileURL.pathComponents
    let normalizedBase = baseDirectory.standardizedFileURL.pathComponents
    guard normalizedPath.count >= normalizedBase.count else { return false }
    return Array(normalizedPath.prefix(normalizedBase.count)) == normalizedBase
  }
}

private nonisolated func blockingScriptExitMessage(_ exitCode: Int) -> String {
  switch exitCode {
  case 1: return "Script failed (exit code 1)."
  case 126: return "Permission denied (exit code 126)."
  case 127: return "Command not found (exit code 127)."
  case 129...: return "Script killed by signal \(exitCode - 128) (exit code \(exitCode))."
  default: return "Script exited with code \(exitCode)."
  }
}

private nonisolated func worktreeCreateCommand(
  baseDirectoryURL: URL,
  name: String,
  copyFiles: (ignored: Bool, untracked: Bool),
  baseRef: String,
  directoryOverride: URL?
) -> String {
  let baseDir = baseDirectoryURL.path(percentEncoded: false)
  var parts = ["wt", "--base-dir", baseDir, "sw"]
  if copyFiles.ignored {
    parts.append("--copy-ignored")
  }
  if copyFiles.untracked {
    parts.append("--copy-untracked")
  }
  if !baseRef.isEmpty {
    parts.append("--from")
    parts.append(baseRef)
  }
  if let directoryOverride {
    parts.append("--path")
    parts.append(directoryOverride.path(percentEncoded: false))
  }
  if copyFiles.ignored || copyFiles.untracked {
    parts.append("--verbose")
  }
  parts.append(name)
  return parts.map(shellQuote).joined(separator: " ")
}

private nonisolated func shellQuote(_ value: String) -> String {
  let needsQuoting = value.contains { character in
    character.isWhitespace || character == "\"" || character == "'" || character == "\\"
  }
  guard needsQuoting else {
    return value
  }
  return "'\(value.replacing("'", with: "'\"'\"'"))'"
}

extension RepositoriesFeature.State {
  mutating func updateWorktreeName(_ worktreeID: Worktree.ID, name: String) {
    for index in repositories.indices {
      let repository = repositories[index]
      guard let worktreeIndex = repository.worktrees.index(id: worktreeID) else { continue }
      let worktree = repository.worktrees[worktreeIndex]
      guard worktree.name != name else { return }
      var worktrees = repository.worktrees
      worktrees[id: worktreeID] = worktree.renamed(name)
      repositories[index] = repository.withWorktrees(worktrees)
      return
    }
  }

  /// Row action dispatch: drops late-emit storms via the row reducer's equality
  /// guard. No parent-side mutation; the row reducer is the canonical writer.
  func setRowLifecycleEffect(
    _ worktreeID: Worktree.ID,
    _ lifecycle: SidebarItemFeature.State.Lifecycle,
  ) -> Effect<RepositoriesFeature.Action> {
    guard let current = sidebarItems[id: worktreeID]?.lifecycle else { return .none }
    guard current != lifecycle else { return .none }
    return .send(.sidebarItems(.element(id: worktreeID, action: .lifecycleChanged(lifecycle))))
  }

  /// Row action dispatch for diff stats. 30 / 60 s polling re-emits the same
  /// line counts on every tick; skip the dispatch when both fields match.
  func updateWorktreeLineChangesEffect(
    worktreeID: Worktree.ID,
    added: Int,
    removed: Int,
  ) -> Effect<RepositoriesFeature.Action> {
    guard let row = sidebarItems[id: worktreeID] else { return .none }
    let nextAdded: Int? = added == 0 && removed == 0 ? nil : added
    let nextRemoved: Int? = added == 0 && removed == 0 ? nil : removed
    guard row.addedLines != nextAdded || row.removedLines != nextRemoved else { return .none }
    return .send(
      .sidebarItems(
        .element(id: worktreeID, action: .diffStatsChanged(added: nextAdded, removed: nextRemoved))
      )
    )
  }

  /// Always dispatches `pullRequestChanged` so the row reducer can clear
  /// `pullRequestBranchAtQueryTime` even when the PR value is unchanged.
  /// The row's own equality guard short-circuits the PR-value mutation.
  func updateWorktreePullRequestEffect(
    worktreeID: Worktree.ID,
    pullRequest: GithubPullRequest?,
    branchAtQueryTime: String? = nil,
  ) -> Effect<RepositoriesFeature.Action> {
    guard let row = sidebarItems[id: worktreeID] else { return .none }
    let branch = branchAtQueryTime ?? row.branchName
    return .send(
      .sidebarItems(
        .element(
          id: worktreeID,
          action: .pullRequestChanged(pullRequest, branchAtQueryTime: branch)
        )
      )
    )
  }
}

extension Dictionary where Key == Repository.ID, Value == RepositoriesFeature.PendingPullRequestRefresh {
  mutating func queuePullRequestRefresh(
    repositoryID: Repository.ID,
    repositoryRootURL: URL,
    worktreeIDs: [Worktree.ID],
  ) {
    if var pending = self[repositoryID] {
      var seenWorktreeIDs = Set(pending.worktreeIDs)
      for worktreeID in worktreeIDs where seenWorktreeIDs.insert(worktreeID).inserted {
        pending.worktreeIDs.append(worktreeID)
      }
      self[repositoryID] = pending
    } else {
      self[repositoryID] = RepositoriesFeature.PendingPullRequestRefresh(
        repositoryRootURL: repositoryRootURL,
        worktreeIDs: worktreeIDs,
      )
    }
  }
}

enum WorktreeHistoryDirection {
  case back, forward
}

/// Browser-style back / forward; older entries are dropped when the cap is hit.
private let worktreeHistoryStackLimit = 50

extension RepositoriesFeature.State {
  mutating func restoreSelection(_ id: Worktree.ID?, pendingID: Worktree.ID) {
    guard selection == .worktree(pendingID) else { return }
    let target = isSelectionValid(id) ? id : nil
    setSingleWorktreeSelection(target, recordHistory: false)
    // The pending-id selection at create time pushed `target` onto the back
    // stack. Restoring to that same id would leave the navigator with a
    // self-referential top entry. Pop the matching entry so the failure
    // path is fully undone in history terms too.
    if let target, worktreeHistoryBackStack.last == target {
      worktreeHistoryBackStack.removeLast()
    }
  }

  func isSelectionValid(_ id: Worktree.ID?) -> Bool {
    guard let id else { return false }
    return worktreeExists(id)
  }

  mutating func setSingleWorktreeSelection(_ worktreeID: Worktree.ID?, recordHistory: Bool = true) {
    let previousID = selectedWorktreeID
    selection = worktreeID.map(SidebarSelection.worktree)
    sidebarSelectedWorktreeIDs = worktreeID.map { [$0] } ?? []
    if recordHistory {
      recordWorktreeHistoryTransition(from: previousID, to: worktreeID)
    }
    if let worktreeID {
      recordWorktreeMRU(worktreeID: worktreeID)
    }
  }

  /// Hoists the selected worktree to the head of `worktreeMRU`. Called from
  /// every user-initiated worktree selection; selection-clearing (nil) paths are
  /// no-ops so a "select nothing" transition can't poison the MRU head.
  mutating func recordWorktreeMRU(worktreeID: Worktree.ID) {
    // A pending creation's synthetic id is transient and never a real row, so
    // recording it would leave a ghost that eventually evicts real worktrees.
    guard !worktreeID.isPending else { return }
    if let existingIndex = worktreeMRU.firstIndex(of: worktreeID) {
      worktreeMRU.remove(at: existingIndex)
    }
    worktreeMRU.insert(worktreeID, at: 0)
    // Cap for parity with the history stacks; the switcher only ever needs the
    // recent head, so an unbounded session-long list buys nothing.
    if worktreeMRU.count > worktreeHistoryStackLimit {
      worktreeMRU.removeLast(worktreeMRU.count - worktreeHistoryStackLimit)
    }
  }

  /// Records a fresh worktree navigation: pushes the previous selection onto
  /// the back stack and clears the forward stack. No-op when the selection
  /// didn't actually change, or when either side is nil. Transitions to / from
  /// "no selection" aren't navigations the user can step forward out of, so
  /// recording them would only inflate the back stack.
  mutating func recordWorktreeHistoryTransition(from previousID: Worktree.ID?, to nextID: Worktree.ID?) {
    guard let previousID, let nextID, previousID != nextID else { return }
    worktreeHistoryBackStack.append(previousID)
    worktreeHistoryForwardStack.removeAll()
    if worktreeHistoryBackStack.count > worktreeHistoryStackLimit {
      worktreeHistoryBackStack.removeFirst(worktreeHistoryBackStack.count - worktreeHistoryStackLimit)
    }
  }

  /// Walks the back / forward stacks until we land on a worktree that still
  /// exists and isn't already selected, then sets the selection without
  /// recording history.
  mutating func navigateWorktreeHistoryEffect(
    direction: WorktreeHistoryDirection,
  ) -> Effect<RepositoriesFeature.Action> {
    while true {
      let candidate: Worktree.ID? = {
        switch direction {
        case .back: worktreeHistoryBackStack.popLast()
        case .forward: worktreeHistoryForwardStack.popLast()
        }
      }()
      guard let candidate else { return .none }
      guard isSelectionValid(candidate) else { continue }
      if selectedWorktreeID == candidate { continue }
      if let currentID = selectedWorktreeID {
        switch direction {
        case .back: worktreeHistoryForwardStack.append(currentID)
        case .forward: worktreeHistoryBackStack.append(currentID)
        }
      }
      setSingleWorktreeSelection(candidate, recordHistory: false)
      var effects: [Effect<RepositoriesFeature.Action>] = [
        .send(.delegate(.selectedWorktreeChanged(worktree(for: candidate))))
      ]
      if sidebarItems[id: candidate] != nil {
        effects.append(
          .send(.sidebarItems(.element(id: candidate, action: .focusTerminalRequested)))
        )
      }
      return .merge(effects)
    }
  }

  mutating func reduceSelectionChangedEffect(
    selections: Set<SidebarSelection>,
    focusTerminal: Bool,
  ) -> Effect<RepositoriesFeature.Action> {
    let previousSelection = selectedWorktreeID
    let previousSelectedWorktree = worktree(for: previousSelection)

    guard !selections.contains(.archivedWorktrees) else {
      selection = .archivedWorktrees
      sidebarSelectedWorktreeIDs = []
      return .send(.delegate(.selectedWorktreeChanged(nil)))
    }

    // Failed-repo selection is exclusive: drop any worktree selection
    // and clear the detail pane's terminal binding.
    if let failedID = selections.compactMap(\.failedRepositoryID).first {
      selection = .failedRepository(failedID)
      sidebarSelectedWorktreeIDs = []
      return .send(.delegate(.selectedWorktreeChanged(nil)))
    }

    // Validate against the live roster + pending entries so a reselect of a
    // still-creating row doesn't fall through to the empty-state; also stays
    // robust when `sidebarGrouping` hasn't been reconciled yet.
    let orderedWorktreeIDs: [Worktree.ID] =
      repositories.flatMap { $0.worktrees.map(\.id) } + pendingWorktrees.map(\.id)
    let allWorktreeIDs = Set(orderedWorktreeIDs)
    let requestedWorktreeIDs = Set(selections.compactMap(\.worktreeID))
    let nextSidebarSelectedWorktreeIDs = requestedWorktreeIDs.intersection(allWorktreeIDs)
    let droppedIDs = requestedWorktreeIDs.subtracting(nextSidebarSelectedWorktreeIDs)
    if !droppedIDs.isEmpty {
      repositoriesLogger.debug("Selection dropped unknown worktree IDs: \(droppedIDs).")
    }

    guard !nextSidebarSelectedWorktreeIDs.isEmpty else {
      setSingleWorktreeSelection(nil)
      return .send(.delegate(.selectedWorktreeChanged(nil)))
    }

    let nextSelectedWorktreeID =
      if let selectedWorktreeID, nextSidebarSelectedWorktreeIDs.contains(selectedWorktreeID) {
        selectedWorktreeID
      } else {
        orderedWorktreeIDs.first(where: nextSidebarSelectedWorktreeIDs.contains)
          ?? nextSidebarSelectedWorktreeIDs.first
      }

    selection = nextSelectedWorktreeID.map(SidebarSelection.worktree)
    sidebarSelectedWorktreeIDs = nextSidebarSelectedWorktreeIDs
    recordWorktreeHistoryTransition(from: previousSelection, to: nextSelectedWorktreeID)
    // Sidebar selection bypasses `setSingleWorktreeSelection`, so record the
    // worktree MRU here too. Otherwise clicking a worktree (the dominant nav
    // path) never updates `worktreeMRU`, and the ⌘P switcher can't put the
    // worktree you actually had open at the top.
    if let nextSelectedWorktreeID {
      recordWorktreeMRU(worktreeID: nextSelectedWorktreeID)
    }
    var effects: [Effect<RepositoriesFeature.Action>] = []
    if focusTerminal,
      let nextSelectedWorktreeID,
      previousSelection != nextSelectedWorktreeID,
      sidebarItems[id: nextSelectedWorktreeID] != nil
    {
      effects.append(
        .send(.sidebarItems(.element(id: nextSelectedWorktreeID, action: .focusTerminalRequested)))
      )
    }

    let selectedWorktree = worktree(for: nextSelectedWorktreeID)
    if hasSelectionChanged(
      previousSelectionID: previousSelection,
      previousSelectedWorktree: previousSelectedWorktree,
      selectedWorktreeID: nextSelectedWorktreeID,
      selectedWorktree: selectedWorktree,
    ) {
      effects.append(.send(.delegate(.selectedWorktreeChanged(selectedWorktree))))
    }
    return .merge(effects)
  }

  func hasSelectionChanged(
    previousSelectionID: Worktree.ID?,
    previousSelectedWorktree: Worktree?,
    selectedWorktreeID: Worktree.ID?,
    selectedWorktree: Worktree?,
  ) -> Bool {
    previousSelectionID != selectedWorktreeID
      || previousSelectedWorktree?.workingDirectory != selectedWorktree?.workingDirectory
      || previousSelectedWorktree?.repositoryRootURL != selectedWorktree?.repositoryRootURL
  }

  /// Only git repositories can host new worktrees. Folders are filtered out so
  /// the "New Worktree" hotkey / palette entry resolves to a sibling git repo
  /// (or nothing) when the current selection lives in a folder.
  var repositoryForWorktreeCreation: Repository? {
    if let selectedWorktreeID {
      if let pending = pendingWorktree(for: selectedWorktreeID),
        let pendingRepo = repositories[id: pending.repositoryID],
        pendingRepo.isGitRepository
      {
        return pendingRepo
      }
      for repository in repositories
      where repository.isGitRepository && repository.worktrees[id: selectedWorktreeID] != nil {
        return repository
      }
    }
    let gitRepositories = repositories.filter(\.isGitRepository)
    return gitRepositories.count == 1 ? gitRepositories.first : nil
  }
}

extension RepositoriesFeature.State {
  /// Clears `.failedRepository(id)` selection once `id` is no longer in
  /// `loadFailuresByID` (it either loaded successfully or was removed),
  /// so the detail pane lets go of `FailedRepositoryDetailView`.
  mutating func dropStaleFailedRepositorySelection() {
    guard case .failedRepository(let id) = selection,
      loadFailuresByID[id] == nil
    else { return }
    selection = nil
  }
}

extension RepositoriesFeature.State {
  /// Reconcile the nested `SidebarState` against the currently-known repositories
  /// + worktrees in one atomic `$sidebar.withLock`. `pruneLivenessAgainstRoster`
  /// gates the destructive drop of `.pinned` / `.unpinned` items whose worktree
  /// isn't in the live roster; pass `false` on the first load to keep curated
  /// items through the hydration race.
  mutating func reconcileSidebarState(roots: [URL], pruneLivenessAgainstRoster: Bool) {
    // Empty-everything reload: bail. A settings-file read failure or a
    // pre-rehydration window with zero roots + zero repos would obliterate
    // curation if we overwrote `sidebar.json` from here.
    if roots.isEmpty, repositories.isEmpty { return }

    let rootIDs: Set<Repository.ID> = Set(
      roots.map { RepositoryID($0.standardizedFileURL.path(percentEncoded: false)) })
    let localIDs = Set(repositories.map(\.id))
    let availableRepoIDs = localIDs.union(rootIDs)
    let repositoriesByID = Dictionary(uniqueKeysWithValues: repositories.map { ($0.id, $0) })

    var rebuilt: OrderedDictionary<Repository.ID, SidebarState.Section> = [:]
    for (repoID, section) in sidebar.sections where availableRepoIDs.contains(repoID) {
      guard let repository = repositoriesByID[repoID] else {
        // Local roots still loading. Preserve the section verbatim.
        rebuilt[repoID] = section
        continue
      }
      // Folder synthetic worktrees satisfy `isMainWorktree` by geometry but are
      // user-pinnable. Scope the main-worktree skip to git repos so a pin on a
      // folder survives `.repositoriesLoaded`.
      let mainID =
        repository.isGitRepository ? repository.worktrees.first(where: { isMainWorktree($0) })?.id : nil
      let worktreeIDs = Set(repository.worktrees.map(\.id))
      // A disconnected remote is an empty placeholder (resolved remotes always have
      // >=1 worktree); skip its prune so a pin survives the disconnect.
      let isUnresolvedRemotePlaceholder = repository.host != nil && repository.worktrees.isEmpty
      let pruneAgainstRoster = pruneLivenessAgainstRoster && !isUnresolvedRemotePlaceholder
      var copy = section
      let mainCustomization = mainID.flatMap { Self.mainWorktreeCustomization(in: copy, mainID: $0) }
      let seenInCuratedBuckets = Self.pruneCuratedBuckets(
        in: &copy, mainID: mainID, liveWorktreeIDs: worktreeIDs, pruneAgainstRoster: pruneAgainstRoster)
      if let mainID, let mainCustomization {
        var unpinned = copy.buckets[.unpinned] ?? .init()
        unpinned.items[mainID] = mainCustomization
        copy.buckets[.unpinned] = unpinned
      }
      Self.seedLiveWorktrees(
        into: &copy, repository: repository, mainID: mainID, seenInCuratedBuckets: seenInCuratedBuckets)
      // Same carve-out: a disconnected remote's empty roster would otherwise drop
      // every stored branch-collapse prefix.
      if !isUnresolvedRemotePlaceholder {
        Self.pruneCollapsedBranchPrefixes(in: &copy, worktrees: repository.worktrees)
      }
      rebuilt[repoID] = copy
    }

    // Seed a default empty section for every live repository that doesn't yet
    // have a `sidebar.sections` entry, so SwiftUI's List diffing doesn't miss
    // the insertion until the next reconcile pass.
    for repository in repositories where rebuilt[repository.id] == nil {
      rebuilt[repository.id] = SidebarState.Section()
    }

    SidebarState.preserveOrphanSections(
      from: sidebar.sections,
      availableRepoIDs: availableRepoIDs,
      into: &rebuilt,
    )

    // Equality-gate the write so branch-flutter reloads don't re-encode
    // `sidebar.json` on every tick.
    guard rebuilt != sidebar.sections else { return }
    $sidebar.withLock { sidebar in sidebar.sections = rebuilt }
  }

  /// Prunes each curated bucket in place: drops the main worktree (it renders in
  /// the main slot) and, when `pruneAgainstRoster`, any row no longer live.
  /// Returns the worktree IDs kept, so the caller can skip re-seeding them.
  private static func pruneCuratedBuckets(
    in copy: inout SidebarState.Section,
    mainID: Worktree.ID?,
    liveWorktreeIDs: Set<Worktree.ID>,
    pruneAgainstRoster: Bool
  ) -> Set<Worktree.ID> {
    var seen: Set<Worktree.ID> = []
    for (bucketID, bucket) in copy.buckets {
      if bucketID == .archived { continue }
      var prunedItems: OrderedDictionary<Worktree.ID, SidebarState.Item> = [:]
      for (worktreeID, item) in bucket.items {
        if let mainID, worktreeID == mainID { continue }
        if pruneAgainstRoster, !liveWorktreeIDs.contains(worktreeID) { continue }
        prunedItems[worktreeID] = item
        seen.insert(worktreeID)
      }
      var prunedBucket = bucket
      prunedBucket.items = prunedItems
      copy.buckets[bucketID] = prunedBucket
    }
    return seen
  }

  /// Seeds every live non-main worktree that isn't already curated or archived into
  /// `.unpinned`. Mutation actions assume every live worktree has a bucket and skip
  /// fallback paths.
  private static func seedLiveWorktrees(
    into copy: inout SidebarState.Section,
    repository: Repository,
    mainID: Worktree.ID?,
    seenInCuratedBuckets: Set<Worktree.ID>
  ) {
    var archivedIDs: Set<Worktree.ID> = []
    if let archivedBucket = copy.buckets[.archived] {
      archivedIDs = Set(archivedBucket.items.keys)
    }
    for worktree in repository.worktrees {
      if let mainID, worktree.id == mainID { continue }
      if seenInCuratedBuckets.contains(worktree.id) || archivedIDs.contains(worktree.id) { continue }
      var unpinned = copy.buckets[.unpinned] ?? .init()
      unpinned.items[worktree.id] = .init()
      copy.buckets[.unpinned] = unpinned
    }
  }

  /// Returns a git main worktree's CLI-set appearance override, if any.
  /// Reconciliation reprojects it into `.unpinned` so the tint / rename survives
  /// roster reloads without making the main worktree user-pinned.
  private static func mainWorktreeCustomization(
    in section: SidebarState.Section,
    mainID: Worktree.ID
  ) -> SidebarState.Item? {
    for bucketID in [SidebarState.BucketID.unpinned, .pinned] {
      guard var item = section.buckets[bucketID]?.items[mainID],
        item.title != nil || item.color != nil
      else { continue }
      item.archivedAt = nil
      return item
    }
    return nil
  }

  /// Drop persisted `collapsedBranchPrefixes` entries no longer covered by any
  /// live branch in this repo, so `sidebar.json` doesn't grow unbounded as
  /// users rename / delete worktrees. Does NOT drop prefixes that still cover
  /// a single live branch (those won't emit a header today due to chain
  /// collapse, but will start emitting one again the moment a sibling branch
  /// is added, and the stored collapse state is the right pre-seed). `Worktree.name`
  /// is the branch name (see `RepositoriesFeature+Sidebar.swift`).
  static func pruneCollapsedBranchPrefixes(
    in section: inout SidebarState.Section,
    worktrees: IdentifiedArrayOf<Worktree>
  ) {
    let liveBranchNames = Set(worktrees.map(\.name))
    let coveredPrefixes = Set(liveBranchNames.flatMap(SidebarBranchNesting.ancestorPrefixes(of:)))
    for bucketID in [SidebarState.BucketID.pinned, .unpinned] {
      guard var bucket = section.buckets[bucketID] else { continue }
      let next = bucket.collapsedBranchPrefixes.intersection(coveredPrefixes)
      guard next != bucket.collapsedBranchPrefixes else { continue }
      bucket.collapsedBranchPrefixes = next
      section.buckets[bucketID] = bucket
    }
  }

  @discardableResult
  mutating func pruneArchivedWorktreeIDs(availableWorktreeIDs: Set<Worktree.ID>) -> Bool {
    var didChange = false
    $sidebar.withLock { sidebar in
      for (repoID, section) in sidebar.sections {
        guard let archived = section.buckets[.archived] else { continue }
        for worktreeID in archived.items.keys where !availableWorktreeIDs.contains(worktreeID) {
          sidebar.sections[repoID]?.buckets[.archived]?.items.removeValue(forKey: worktreeID)
          didChange = true
        }
      }
    }
    return didChange
  }

  func firstAvailableWorktreeID(from repositories: [Repository]) -> Worktree.ID? {
    for repository in repositories {
      if let first = orderedWorktrees(in: repository).first { return first.id }
    }
    return nil
  }

  func firstAvailableWorktreeID(in repositoryID: Repository.ID) -> Worktree.ID? {
    guard let repository = repositories[id: repositoryID] else { return nil }
    return orderedWorktrees(in: repository).first?.id
  }

  func nextWorktreeID(afterRemoving worktree: Worktree, in repository: Repository) -> Worktree.ID? {
    let orderedIDs = orderedWorktrees(in: repository).map(\.id)
    guard let index = orderedIDs.firstIndex(of: worktree.id) else { return nil }
    let nextIndex = index + 1
    if nextIndex < orderedIDs.count { return orderedIDs[nextIndex] }
    if index > 0 { return orderedIDs[index - 1] }
    return nil
  }
}

extension SidebarState {
  /// Preserve user-curated `.archived` / `.pinned` buckets and title / color
  /// customization for repositories no longer in `availableRepoIDs`. Tombstones
  /// are appended after live repos so the natural ordering stays "live first,
  /// orphan-but-curated at the tail". `.unpinned` is dropped (regenerated by
  /// the seed pass) and `collapsed` resets to its default.
  fileprivate static func preserveOrphanSections(
    from oldSections: OrderedDictionary<Repository.ID, SidebarState.Section>,
    availableRepoIDs: Set<Repository.ID>,
    into rebuilt: inout OrderedDictionary<Repository.ID, SidebarState.Section>,
  ) {
    for (repoID, section) in oldSections where !availableRepoIDs.contains(repoID) {
      var preservedBuckets: OrderedDictionary<SidebarState.BucketID, SidebarState.Bucket> = [:]
      if let archived = section.buckets[.archived], !archived.items.isEmpty {
        preservedBuckets[.archived] = archived
      }
      if let pinned = section.buckets[.pinned], !pinned.items.isEmpty {
        preservedBuckets[.pinned] = pinned
      }
      let hasCustomization = section.title != nil || section.color != nil
      guard !preservedBuckets.isEmpty || hasCustomization else { continue }
      rebuilt[repoID] = .init(
        collapsed: false,
        buckets: preservedBuckets,
        title: section.title,
        color: section.color,
      )
    }
  }
}

extension String {
  /// Returns the remote name if this ref starts with `<remote>/`, matched against known remotes.
  fileprivate nonisolated func matchingRemote(from remotes: [String]) -> String? {
    GitReferenceQueries.remotePrefixMatch(ref: self, remoteNames: remotes)?.remote
  }
}
