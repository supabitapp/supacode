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
  static func delayedPRRefresh(_ worktreeID: Worktree.ID) -> String {
    "repositories.delayedPRRefresh.\(worktreeID)"
  }
}

nonisolated let repositoriesLogger = SupaLogger("Repositories")
private nonisolated let githubIntegrationRecoveryInterval: Duration = .seconds(15)

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
    var selection: SidebarSelection?
    var worktreeInfoByID: [Worktree.ID: WorktreeInfoEntry] = [:]
    var isOpenPanelPresented = false
    var isInitialLoadComplete = false
    var pendingWorktrees: [PendingWorktree] = []
    var pendingSetupScriptWorktreeIDs: Set<Worktree.ID> = []
    var pendingTerminalFocusWorktreeIDs: Set<Worktree.ID> = []
    var runningScriptsByWorktreeID: [Worktree.ID: [UUID: TerminalTabTintColor]] = [:]
    var archivingWorktreeIDs: Set<Worktree.ID> = []
    var deleteScriptWorktreeIDs: Set<Worktree.ID> = []
    var deletingWorktreeIDs: Set<Worktree.ID> = []
    /// Repositories with an in-flight removal. The value records
    /// the removal intent confirmed for this repo.
    /// `.deleteScriptCompleted` routes by the stored intent rather
    /// than by live kind classification (which a `git init`
    /// mid-delete could flip). An empty key means no removal;
    /// presence also drives the sidebar's "removing" indicator.
    /// In-flight repo-level removals keyed by repository id. Each
    /// record carries the disposition (which only ever holds
    /// `.gitRepositoryUnlink` / `.folderUnlink` / `.folderTrash` —
    /// the per-worktree `.gitWorktreeDelete` flow uses
    /// `deletingWorktreeIDs` instead) and the id of the batch
    /// aggregator responsible for draining its per-target
    /// completion. Folding disposition + batch id into one record
    /// keeps them in lockstep: a repo can't be "being removed"
    /// without an owning batch, and a batch always knows the
    /// disposition of each of its targets.
    var removingRepositoryIDs: [Repository.ID: RepositoryRemovalRecord] = [:]
    /// Bulk-removal aggregators keyed by batch id. Populated by the
    /// confirm handler for repo-level deletes (folder rows + git-repo
    /// section removals). As each per-target completion arrives via
    /// `.repositoryRemovalCompleted`, its id is drained from
    /// `pending` and (if succeeded) appended to `succeeded`. The
    /// batch fires a single `.repositoriesRemoved([ids], ...)` when
    /// `pending` is empty, replacing the per-target reloads that
    /// previously raced through `CancelID.persistRoots`. The dict
    /// (rather than a single optional) lets overlapping removals —
    /// e.g. a folder bulk trash in-flight while the user confirms a
    /// git-repo section remove — each complete independently
    /// without clobbering each other's pending set.
    var activeRemovalBatches: [BatchID: ActiveRemovalBatch] = [:]
    var autoDeleteArchivedWorktreesAfterDays: AutoDeletePeriod?
    var mergedWorktreeAction: MergedWorktreeAction?
    var moveNotifiedWorktreeToTop = true
    var shouldRestoreLastFocusedWorktree = false
    var shouldSelectFirstAfterReload = false
    var isRefreshingWorktrees = false
    var statusToast: StatusToast?
    var githubIntegrationAvailability: GithubIntegrationAvailability = .unknown
    var pendingPullRequestRefreshByRepositoryID: [Repository.ID: PendingPullRequestRefresh] = [:]
    var inFlightPullRequestRefreshRepositoryIDs: Set<Repository.ID> = []
    var queuedPullRequestRefreshByRepositoryID: [Repository.ID: PendingPullRequestRefresh] = [:]
    var sidebarSelectedWorktreeIDs: Set<Worktree.ID> = []
    var nextPendingSidebarRevealID = 0
    var pendingSidebarReveal: PendingSidebarReveal?
    /// Single source of truth for all user-curated sidebar state —
    /// section order / collapse / pin / unpin / archive / focused
    /// worktree — persisted to `~/.supacode/sidebar.json`. Replaces
    /// the six legacy slices (pin / archive / repo order / worktree
    /// order / focus / collapsed). All co-mutating actions fold
    /// through `$sidebar.withLock` so the SharedKey emits a single
    /// atomic file update per reducer action.
    @Shared(.sidebar) var sidebar: SidebarState
    @Presents var worktreeCreationPrompt: WorktreeCreationPromptFeature.State?
    @Presents var repositoryCustomization: RepositoryCustomizationFeature.State?
    @Presents var alert: AlertState<Alert>?
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
    case task
    case setOpenPanelPresented(Bool)
    case loadPersistedRepositories
    case refreshWorktrees
    case reloadRepositories(animated: Bool)
    case repositoriesLoaded([Repository], failures: [LoadFailure], roots: [URL], animated: Bool)
    case selectionChanged(Set<SidebarSelection>, focusTerminal: Bool = false)
    case repositoryExpansionChanged(Repository.ID, isExpanded: Bool)
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
    case selectNextWorktree
    case selectPreviousWorktree
    case revealSelectedWorktreeInSidebar
    case consumePendingSidebarReveal(Int)
    case requestRenameBranch(Worktree.ID, String)
    case createRandomWorktree
    case createRandomWorktreeInRepository(Repository.ID)
    case createWorktreeInRepository(
      repositoryID: Repository.ID,
      nameSource: WorktreeCreationNameSource,
      baseRefSource: WorktreeCreationBaseRefSource,
      fetchOrigin: Bool
    )
    case promptedWorktreeCreationDataLoaded(
      repositoryID: Repository.ID,
      baseRefOptions: [String],
      automaticBaseRef: String,
      selectedBaseRef: String?
    )
    case startPromptedWorktreeCreation(
      repositoryID: Repository.ID,
      branchName: String,
      baseRef: String?,
      fetchOrigin: Bool
    )
    case promptedWorktreeCreationChecked(
      repositoryID: Repository.ID,
      branchName: String,
      baseRef: String?,
      fetchOrigin: Bool,
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
      worktreeID: Worktree.ID, scriptID: UUID, kind: BlockingScriptKind, exitCode: Int?, tabId: TerminalTabID?)
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
    case worktreeNotificationReceived(Worktree.ID)
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
    case setMergedWorktreeAction(MergedWorktreeAction?)
    case setAutoDeleteArchivedWorktreesAfterDays(AutoDeletePeriod?)
    case autoDeleteExpiredArchivedWorktrees
    case setMoveNotifiedWorktreeToTop(Bool)
    case pullRequestAction(Worktree.ID, PullRequestAction)
    case showToast(StatusToast)
    case dismissToast
    case delayedPullRequestRefresh(Worktree.ID)
    case openRepositorySettings(Repository.ID)
    case requestCustomizeRepository(Repository.ID)
    case contextMenuOpenWorktree(Worktree.ID, OpenWorktreeAction)
    case worktreeCreationPrompt(PresentationAction<WorktreeCreationPromptFeature.Action>)
    case repositoryCustomization(PresentationAction<RepositoryCustomizationFeature.Action>)
    case alert(PresentationAction<Alert>)
    case delegate(Delegate)
  }

  struct LoadFailure: Equatable {
    let rootID: Repository.ID
    let message: String
  }

  struct DeleteWorktreeTarget: Equatable {
    let worktreeID: Worktree.ID
    let repositoryID: Repository.ID
  }

  struct ArchiveWorktreeTarget: Equatable {
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

  enum Alert: Equatable {
    case confirmArchiveWorktree(Worktree.ID, Repository.ID)
    case confirmArchiveWorktrees([ArchiveWorktreeTarget])
    case confirmDeleteSidebarItems([DeleteWorktreeTarget], disposition: DeleteDisposition)
    case confirmDeleteRepository(Repository.ID)
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
  @Dependency(\.date.now) private var now
  @Dependency(\.uuid) private var uuid

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .task:
        // `sidebar` is already hydrated from `sidebar.json` (loaded
        // synchronously by the SharedKey when State is constructed),
        // so `.task` has no persistence fan-out left — it just flags
        // the focus restore and kicks off the repository load.
        state.shouldRestoreLastFocusedWorktree = state.sidebar.focusedWorktreeID != nil
        return .send(.loadPersistedRepositories)

      case .setOpenPanelPresented(let isPresented):
        state.isOpenPanelPresented = isPresented
        return .none

      case .loadPersistedRepositories:
        state.alert = nil
        state.isRefreshingWorktrees = false
        return .run { send in
          let loadedPaths = await repositoryPersistence.loadRoots()
          let rootPaths = RepositoryPathNormalizer.normalize(loadedPaths)
          let roots = rootPaths.map { URL(fileURLWithPath: $0) }
          let (repositories, failures) = await loadRepositoriesData(roots)
          await send(
            .repositoriesLoaded(
              repositories,
              failures: failures,
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
        // Deliberately NOT clearing `state.alert` here —
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
        guard !roots.isEmpty else {
          state.isRefreshingWorktrees = false
          return .none
        }
        return loadRepositories(roots, animated: animated)

      case .repositoriesLoaded(let repositories, let failures, let roots, let animated):
        state.isRefreshingWorktrees = false
        let previousSelection = state.selectedWorktreeID
        let previousSelectedWorktree = state.worktree(for: previousSelection)
        let incomingRepositories = IdentifiedArray(uniqueElements: repositories)
        let repositoriesChanged = incomingRepositories != state.repositories
        _ = applyRepositories(
          repositories,
          roots: roots,
          shouldPruneArchivedWorktreeIDs: failures.isEmpty,
          state: &state,
          animated: animated
        )
        state.repositoryRoots = roots
        state.isInitialLoadComplete = true
        state.loadFailuresByID = Dictionary(
          uniqueKeysWithValues: failures.map { ($0.rootID, $0.message) }
        )
        let selectedWorktree = state.worktree(for: state.selectedWorktreeID)
        let selectionChanged = selectionDidChange(
          previousSelectionID: previousSelection,
          previousSelectedWorktree: previousSelectedWorktree,
          selectedWorktreeID: state.selectedWorktreeID,
          selectedWorktree: selectedWorktree
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
        // so no per-slice save effects are needed here — the SharedKey
        // writes `sidebar.json` atomically.
        if state.autoDeleteArchivedWorktreesAfterDays != nil {
          allEffects.append(.send(.autoDeleteExpiredArchivedWorktrees))
        }
        return .merge(allEffects)

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
              // `gitClient.repoRoot` throws for non-git paths, but
              // also for transient `wt` / subprocess failures. To
              // avoid silently reclassifying a git repo as a folder
              // on transient errors, double-check via the injected
              // `gitClient.isGitRepository` — if the path actually
              // has `.git`, surface the original error as an invalid
              // root. Non-git readable directories are accepted as
              // folder-kind repositories.
              let standardized = url.standardizedFileURL
              var isDirectory: ObjCBool = false
              let exists = FileManager.default.fileExists(
                atPath: standardized.path(percentEncoded: false),
                isDirectory: &isDirectory
              )
              if exists, isDirectory.boolValue,
                await !gitClient.isGitRepository(standardized)
              {
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
          let (repositories, failures) = await loadRepositoriesData(mergedRoots)
          await send(
            .openRepositoriesFinished(
              repositories,
              failures: failures,
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
        _ = applyRepositories(
          repositories,
          roots: roots,
          shouldPruneArchivedWorktreeIDs: failures.isEmpty,
          state: &state,
          animated: false
        )
        state.repositoryRoots = roots
        state.isInitialLoadComplete = true
        state.loadFailuresByID = Dictionary(
          uniqueKeysWithValues: failures.map { ($0.rootID, $0.message) }
        )
        if !invalidRoots.isEmpty {
          let message = invalidRoots.map { "Supacode couldn't read \($0)." }.joined(separator: "\n")
          state.alert = messageAlert(
            title: "Some items couldn't be opened",
            message: message
          )
        }
        let selectedWorktree = state.worktree(for: state.selectedWorktreeID)
        let selectionChanged = selectionDidChange(
          previousSelectionID: previousSelection,
          previousSelectedWorktree: previousSelectedWorktree,
          selectedWorktreeID: state.selectedWorktreeID,
          selectedWorktree: selectedWorktree
        )
        var allEffects: [Effect<Action>] = [
          .send(.delegate(.repositoriesChanged(state.repositories)))
        ]
        if selectionChanged {
          allEffects.append(.send(.delegate(.selectedWorktreeChanged(selectedWorktree))))
        }
        // See `.repositoriesLoaded` above for why no per-slice save
        // effects run here — sidebar mutations already flushed.
        if state.autoDeleteArchivedWorktreesAfterDays != nil {
          allEffects.append(.send(.autoDeleteExpiredArchivedWorktrees))
        }
        return .merge(allEffects)

      case .selectionChanged(let selections, let focusTerminal):
        return reduceSelectionChanged(
          into: &state,
          selections: selections,
          focusTerminal: focusTerminal
        )

      case .repositoryExpansionChanged(let repositoryID, let isExpanded):
        state.$sidebar.withLock { sidebar in
          // Writing the explicit bit (true / false) instead of
          // adding/removing from a set lets future default-flip
          // logic distinguish "user expanded" from "never touched".
          sidebar.sections[repositoryID, default: .init()].collapsed = !isExpanded
        }
        return .none

      case .selectArchivedWorktrees:
        state.selection = .archivedWorktrees
        state.sidebarSelectedWorktreeIDs = []
        return .send(.delegate(.selectedWorktreeChanged(nil)))

      case .setSidebarSelectedWorktreeIDs(let worktreeIDs):
        let validWorktreeIDs = Set(state.orderedSidebarItems().map(\.id))
        var nextWorktreeIDs = worktreeIDs.intersection(validWorktreeIDs)
        if let selectedWorktreeID = state.selectedWorktreeID, validWorktreeIDs.contains(selectedWorktreeID) {
          nextWorktreeIDs.insert(selectedWorktreeID)
        }
        state.sidebarSelectedWorktreeIDs = nextWorktreeIDs
        return .none

      case .selectWorktree(let worktreeID, let focusTerminal):
        setSingleWorktreeSelection(worktreeID, state: &state)
        if focusTerminal, let worktreeID {
          state.pendingTerminalFocusWorktreeIDs.insert(worktreeID)
        }
        let selectedWorktree = state.worktree(for: worktreeID)
        return .send(.delegate(.selectedWorktreeChanged(selectedWorktree)))

      case .selectNextWorktree:
        guard let id = state.worktreeID(byOffset: 1) else { return .none }
        return .send(.selectWorktree(id))

      case .selectPreviousWorktree:
        guard let id = state.worktreeID(byOffset: -1) else { return .none }
        return .send(.selectWorktree(id))

      case .revealSelectedWorktreeInSidebar:
        guard let worktreeID = state.selectedWorktreeID,
          let repositoryID = state.repositoryID(containing: worktreeID)
        else { return .none }
        state.$sidebar.withLock { sidebar in
          sidebar.sections[repositoryID, default: .init()].collapsed = false
        }
        state.nextPendingSidebarRevealID += 1
        state.pendingSidebarReveal = .init(id: state.nextPendingSidebarRevealID, worktreeID: worktreeID)
        return .none

      case .consumePendingSidebarReveal(let pendingSidebarRevealID):
        guard state.pendingSidebarReveal?.id == pendingSidebarRevealID else { return .none }
        state.pendingSidebarReveal = nil
        return .none

      case .requestRenameBranch(let worktreeID, let branchName):
        guard let worktree = state.worktree(for: worktreeID) else { return .none }
        let trimmed = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
          state.alert = messageAlert(
            title: "Branch name required",
            message: "Enter a branch name to rename."
          )
          return .none
        }
        guard !trimmed.contains(where: \.isWhitespace) else {
          state.alert = messageAlert(
            title: "Branch name invalid",
            message: "Branch names can't contain spaces."
          )
          return .none
        }
        if trimmed == worktree.name {
          return .none
        }
        analyticsClient.capture("branch_renamed", nil)
        return .run { send in
          do {
            try await gitClient.renameBranch(worktree.workingDirectory, trimmed)
            await send(.reloadRepositories(animated: true))
          } catch {
            await send(
              .presentAlert(
                title: "Unable to rename branch",
                message: error.localizedDescription
              )
            )
          }
        }

      case .createRandomWorktree:
        guard let repository = repositoryForWorktreeCreation(state) else {
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

      case .createRandomWorktreeInRepository(let repositoryID):
        guard let repository = state.repositories[id: repositoryID] else {
          state.alert = messageAlert(
            title: "Unable to create worktree",
            message: "Unable to resolve a repository for the new worktree."
          )
          return .none
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
          return .none
        }
        if state.removingRepositoryIDs[repository.id] != nil {
          state.alert = messageAlert(
            title: "Unable to create worktree",
            message: "This repository is being removed."
          )
          return .none
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
                fetchOrigin: settingsFile.global.fetchOriginBeforeWorktreeCreation
              )
            )
          )
        }
        @Shared(.repositorySettings(repository.rootURL)) var repositorySettings
        let selectedBaseRef = repositorySettings.worktreeBaseRef
        let gitClient = gitClient
        let rootURL = repository.rootURL
        return .run { send in
          let automaticBaseRef = await gitClient.automaticWorktreeBaseRef(rootURL) ?? "HEAD"
          guard !Task.isCancelled else {
            return
          }
          let baseRefOptions: [String]
          do {
            let refs = try await gitClient.branchRefs(rootURL)
            guard !Task.isCancelled else {
              return
            }
            var options = refs
            if !automaticBaseRef.isEmpty, !options.contains(automaticBaseRef) {
              options.append(automaticBaseRef)
            }
            if let selectedBaseRef, !selectedBaseRef.isEmpty, !options.contains(selectedBaseRef) {
              options.append(selectedBaseRef)
            }
            baseRefOptions = options.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
          } catch {
            guard !Task.isCancelled else {
              return
            }
            var options: [String] = []
            if !automaticBaseRef.isEmpty {
              options.append(automaticBaseRef)
            }
            if let selectedBaseRef, !selectedBaseRef.isEmpty, !options.contains(selectedBaseRef) {
              options.append(selectedBaseRef)
            }
            baseRefOptions = options
          }
          guard !Task.isCancelled else {
            return
          }
          await send(
            .promptedWorktreeCreationDataLoaded(
              repositoryID: repositoryID,
              baseRefOptions: baseRefOptions,
              automaticBaseRef: automaticBaseRef,
              selectedBaseRef: selectedBaseRef
            )
          )
        }
        .cancellable(id: CancelID.worktreePromptLoad, cancelInFlight: true)

      case .promptedWorktreeCreationDataLoaded(
        let repositoryID,
        let baseRefOptions,
        let automaticBaseRef,
        let selectedBaseRef
      ):
        guard let repository = state.repositories[id: repositoryID] else {
          return .none
        }
        @Shared(.settingsFile) var promptSettingsFile
        state.worktreeCreationPrompt = WorktreeCreationPromptFeature.State(
          repositoryID: repository.id,
          repositoryName: repository.name,
          automaticBaseRef: automaticBaseRef,
          baseRefOptions: baseRefOptions,
          branchName: "",
          selectedBaseRef: selectedBaseRef,
          fetchOrigin: promptSettingsFile.global.fetchOriginBeforeWorktreeCreation,
          validationMessage: nil
        )
        return .none

      case .worktreeCreationPrompt(.presented(.delegate(.cancel))):
        state.worktreeCreationPrompt = nil
        return .merge(
          .cancel(id: CancelID.worktreePromptLoad),
          .cancel(id: CancelID.worktreePromptValidation)
        )

      case .worktreeCreationPrompt(
        .presented(.delegate(.submit(let repositoryID, let branchName, let baseRef, let fetchOrigin)))
      ):
        return .send(
          .startPromptedWorktreeCreation(
            repositoryID: repositoryID,
            branchName: branchName,
            baseRef: baseRef,
            fetchOrigin: fetchOrigin
          )
        )

      case .startPromptedWorktreeCreation(let repositoryID, let branchName, let baseRef, let fetchOrigin):
        guard let repository = state.repositories[id: repositoryID] else {
          state.worktreeCreationPrompt = nil
          state.alert = messageAlert(
            title: "Unable to create worktree",
            message: "Unable to resolve a repository for the new worktree."
          )
          return .none
        }
        state.worktreeCreationPrompt?.validationMessage = nil
        state.worktreeCreationPrompt?.isValidating = true
        let normalizedBranchName = branchName.lowercased()
        if repository.worktrees.contains(where: { $0.name.lowercased() == normalizedBranchName }) {
          state.worktreeCreationPrompt?.isValidating = false
          state.worktreeCreationPrompt?.validationMessage = "Branch name already exists."
          return .none
        }
        let gitClient = gitClient
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
        let duplicateMessage
      ):
        guard let prompt = state.worktreeCreationPrompt, prompt.repositoryID == repositoryID else {
          return .none
        }
        state.worktreeCreationPrompt?.isValidating = false
        if let duplicateMessage {
          state.worktreeCreationPrompt?.validationMessage = duplicateMessage
          return .none
        }
        state.worktreeCreationPrompt = nil
        return .send(
          .createWorktreeInRepository(
            repositoryID: repositoryID,
            nameSource: .explicit(branchName),
            baseRefSource: .explicit(baseRef),
            fetchOrigin: fetchOrigin
          )
        )

      case .createWorktreeInRepository(let repositoryID, let nameSource, let baseRefSource, let fetchOrigin):
        guard let repository = state.repositories[id: repositoryID] else {
          state.alert = messageAlert(
            title: "Unable to create worktree",
            message: "Unable to resolve a repository for the new worktree."
          )
          return .none
        }
        // Guard against folder-kind entries arriving here via
        // deeplink / palette paths that bypass
        // `.createRandomWorktreeInRepository`.
        if !repository.isGitRepository {
          state.alert = messageAlert(
            title: "Unable to create worktree",
            message: "Worktrees are only supported for git repositories."
          )
          return .none
        }
        if state.removingRepositoryIDs[repository.id] != nil {
          state.alert = messageAlert(
            title: "Unable to create worktree",
            message: "This repository is being removed."
          )
          return .none
        }
        let previousSelection = state.selectedWorktreeID
        let pendingID = "pending:\(uuid().uuidString)"
        @Shared(.settingsFile) var settingsFile
        @Shared(.repositorySettings(repository.rootURL)) var repositorySettings
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
        state.pendingWorktrees.append(
          PendingWorktree(
            id: pendingID,
            repositoryID: repository.id,
            progress: WorktreeCreationProgress(stage: .loadingLocalBranches, worktreeName: initialWorktreeName)
          )
        )
        setSingleWorktreeSelection(pendingID, state: &state)
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
              copyIgnored: copyIgnored,
              copyUntracked: copyUntracked,
              baseRef: resolvedBaseRef
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
              resolvedBaseRef
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

      case .worktreeCreationPrompt(.dismiss):
        state.worktreeCreationPrompt = nil
        return .merge(
          .cancel(id: CancelID.worktreePromptLoad),
          .cancel(id: CancelID.worktreePromptValidation)
        )

      case .worktreeCreationPrompt:
        return .none

      case .pendingWorktreeProgressUpdated(let id, let progress):
        updatePendingWorktreeProgress(id, progress: progress, state: &state)
        return .none

      case .createRandomWorktreeSucceeded(
        let worktree,
        let repositoryID,
        let pendingID
      ):
        analyticsClient.capture("worktree_created", nil)
        state.pendingSetupScriptWorktreeIDs.insert(worktree.id)
        state.pendingTerminalFocusWorktreeIDs.insert(worktree.id)
        removePendingWorktree(pendingID, state: &state)
        if state.selection == .worktree(pendingID) {
          setSingleWorktreeSelection(worktree.id, state: &state)
        }
        insertWorktree(worktree, repositoryID: repositoryID, state: &state)
        return .merge(
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
        removePendingWorktree(pendingID, state: &state)
        restoreSelection(previousSelection, pendingID: pendingID, state: &state)
        let cleanup = cleanupFailedWorktree(
          repositoryID: repositoryID,
          name: name,
          baseDirectory: baseDirectory,
          state: &state
        )
        state.alert = messageAlert(title: title, message: message)
        let selectedWorktree = state.worktree(for: state.selectedWorktreeID)
        let selectionChanged = selectionDidChange(
          previousSelectionID: previousSelection,
          previousSelectedWorktree: previousSelectedWorktree,
          selectedWorktreeID: state.selectedWorktreeID,
          selectedWorktree: selectedWorktree
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
          let repositoryRootURL = cleanupWorktree.repositoryRootURL
          effects.append(
            .run { send in
              _ = try? await gitClient.removeWorktree(cleanupWorktree, true)
              _ = try? await gitClient.pruneWorktrees(repositoryRootURL)
              await send(.reloadRepositories(animated: true))
            }
          )
        }
        return .merge(effects)

      case .consumeSetupScript(let id):
        state.pendingSetupScriptWorktreeIDs.remove(id)
        return .none

      case .consumeTerminalFocus(let id):
        state.pendingTerminalFocusWorktreeIDs.remove(id)
        return .none

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
        if state.deletingWorktreeIDs.contains(worktree.id)
          || state.deleteScriptWorktreeIDs.contains(worktree.id)
        {
          return .none
        }
        if state.archivingWorktreeIDs.contains(worktree.id) {
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
        state.alert = AlertState {
          TextState("Archive worktree?")
        } actions: {
          ButtonState(role: .destructive, action: .confirmArchiveWorktree(worktree.id, repository.id)) {
            TextState("Archive (⌘↩)")
          }
          ButtonState(role: .cancel) {
            TextState("Cancel")
          }
        } message: {
          TextState(
            "You can find \(worktree.name) later in Menu Bar > Worktrees > Archived Worktrees (\(archivedDisplay))."
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
          if state.isMainWorktree(worktree)
            || state.deletingWorktreeIDs.contains(worktree.id)
            || state.deleteScriptWorktreeIDs.contains(worktree.id)
            || state.archivingWorktreeIDs.contains(worktree.id)
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
            TextState("Archive \(count) (⌘↩)")
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

      case .scriptCompleted(let worktreeID, let scriptID, let kind, let exitCode, let tabId):
        guard var ids = state.runningScriptsByWorktreeID[worktreeID], ids[scriptID] != nil else {
          repositoriesLogger.debug("Ignoring scriptCompleted for \(worktreeID)/\(scriptID): not tracked")
          return .none
        }
        ids.removeValue(forKey: scriptID)
        if ids.isEmpty {
          state.runningScriptsByWorktreeID.removeValue(forKey: worktreeID)
        } else {
          state.runningScriptsByWorktreeID[worktreeID] = ids
        }
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
        if state.isWorktreeArchived(worktreeID) || state.archivingWorktreeIDs.contains(worktreeID) {
          state.alert = nil
          return .none
        }
        state.alert = nil
        @Shared(.repositorySettings(worktree.repositoryRootURL)) var repositorySettings
        let script = repositorySettings.archiveScript
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
          return .send(.archiveWorktreeApply(worktreeID, repositoryID))
        }
        state.archivingWorktreeIDs.insert(worktreeID)
        return .send(
          .delegate(.runBlockingScript(worktree, repositoryID: repositoryID, kind: .archive, script: script)))

      case .archiveScriptCompleted(let worktreeID, let exitCode, let tabId):
        guard state.archivingWorktreeIDs.contains(worktreeID) else {
          repositoriesLogger.debug("Ignoring archiveScriptCompleted for \(worktreeID): not in archivingWorktreeIDs")
          return .none
        }
        state.archivingWorktreeIDs.remove(worktreeID)
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
            return .none
          }
          return .send(.archiveWorktreeApply(worktreeID, repositoryID))
        case nil:
          repositoriesLogger.debug("Archive script cancelled or tab closed for worktree \(worktreeID)")
          return .none
        case let code?:
          state.alert = blockingScriptFailureAlert(
            kind: .archive, exitCode: code, worktreeID: worktreeID, tabId: tabId, state: state
          )
          return .none
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
          ? nextWorktreeID(afterRemoving: worktree, in: repository, state: state)
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
            let nextWorktreeID = nextSelection ?? firstAvailableWorktreeID(in: repositoryID, state: state)
            state.selection = nextWorktreeID.map(SidebarSelection.worktree)
          }
        }
        let repositories = state.repositories
        let selectedWorktree = state.worktree(for: state.selectedWorktreeID)
        let selectionChanged = selectionDidChange(
          previousSelectionID: previousSelection,
          previousSelectedWorktree: previousSelectedWorktree,
          selectedWorktreeID: state.selectedWorktreeID,
          selectedWorktree: selectedWorktree
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
        }
        let repositories = state.repositories
        return .send(.delegate(.repositoriesChanged(repositories)))

      case .requestDeleteSidebarItems(let targets):
        // Kind discriminator: folders skip the main-worktree guard
        // (their synthetic worktree IS main). Mixed kind selections
        // get rejected — the context menu already blocks mixed
        // bulk, so this only trips if a hotkey somehow routes a
        // heterogeneous selection here.
        var validTargets: [DeleteWorktreeTarget] = []
        var validKinds: Set<SidebarItemModel.Kind> = []
        var seenWorktreeIDs: Set<Worktree.ID> = []
        var rejectedMainWorktreeCount = 0
        for target in targets {
          guard seenWorktreeIDs.insert(target.worktreeID).inserted,
            state.removingRepositoryIDs[target.repositoryID] == nil,
            let repository = state.repositories[id: target.repositoryID],
            let worktree = repository.worktrees[id: target.worktreeID],
            !state.deletingWorktreeIDs.contains(worktree.id),
            !state.deleteScriptWorktreeIDs.contains(worktree.id),
            !state.archivingWorktreeIDs.contains(worktree.id)
          else { continue }
          if repository.isGitRepository {
            if state.isMainWorktree(worktree) {
              rejectedMainWorktreeCount += 1
              continue
            }
            validKinds.insert(.git)
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
        let removalSubject =
          count == 1
          ? "the worktree directory and "
            + (deleteBranchOnDeleteWorktree ? "its local branch" : "keep the local branch")
          : "the worktree directories and "
            + (deleteBranchOnDeleteWorktree ? "their local branches" : "keep their local branches")
        let title = count == 1 ? "🚨 Delete worktree?" : "🚨 Delete \(count) worktrees?"
        let buttonLabel = count == 1 ? "Delete (⌘↩)" : "Delete \(count) (⌘↩)"
        let singleTargetName =
          validTargets.first.flatMap {
            state.repositories[id: $0.repositoryID]?.worktrees[id: $0.worktreeID]?.name
          }
        let messageSubject =
          count == 1
          ? "Delete \(singleTargetName ?? "worktree")?"
          : "Delete \(count) worktrees?"
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
          TextState("\(messageSubject) This deletes \(removalSubject).")
        }
        return .none

      case .alert(.presented(.confirmDeleteSidebarItems(let targets, let disposition))):
        // Kind-and-disposition mapping: folders carry the
        // disposition into `removingRepositoryIDs` so
        // `.deleteScriptCompleted` can route by stored choice later.
        // Git worktrees run the standard per-worktree pipeline and
        // don't record a repo-level disposition. Kind / disposition
        // mismatches are impossible under the current alert surface
        // and a caller bypassing those guards is a bug — flag it via
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
                \(target.worktreeID) — git targets only support .gitWorktreeDelete. \
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
                \(target.repositoryID) — folder targets only support .folderUnlink / \
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
          state.activeRemovalBatches[batchID] =
            ActiveRemovalBatch(id: batchID, pending: folderBatchIDs)
        }
        return .merge(
          validTargets.map {
            .send(.deleteSidebarItemConfirmed($0.worktreeID, $0.repositoryID))
          }
        )

      case .deleteSidebarItemConfirmed(let worktreeID, let repositoryID):
        guard let repository = state.repositories[id: repositoryID],
          let worktree = repository.worktrees[id: worktreeID]
        else {
          repositoriesLogger.debug(
            "deleteSidebarItemConfirmed: worktree \(worktreeID) not found in repository \(repositoryID)."
          )
          return .none
        }
        // `deletingWorktreeIDs` / `deleteScriptWorktreeIDs` guard
        // against re-entry for both git worktrees and folders —
        // the empty-script folder branch below populates
        // `deletingWorktreeIDs` so a rapid repeat lands here as a
        // no-op. The first in-flight tap's
        // `.repositoryRemovalCompleted` is the one that drains
        // the aggregator batch; draining here as well would
        // double-drain `batch.pending` and orphan the first tap's
        // completion into the `reportIssue` path.
        if state.archivingWorktreeIDs.contains(worktree.id)
          || state.deletingWorktreeIDs.contains(worktree.id)
          || state.deleteScriptWorktreeIDs.contains(worktree.id)
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
        //     wipe unrelated alerts — specifically the consolidated
        //     trash-failure alert just set by the batch aggregator.
        //   - Deeplink path: same — the caller decides alert state.
        @Shared(.repositorySettings(worktree.repositoryRootURL)) var repositorySettings
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
        if trimmed.isEmpty {
          if let folderIntent {
            // Empty script: finish the folder flow immediately,
            // trashing the directory first if the user asked for it.
            state.deletingWorktreeIDs.insert(worktree.id)
            let selectionWasRemoved = state.selectedWorktreeID == worktreeID
            let trashURL = folderIntent == .folderTrash ? repository.rootURL : nil
            return folderRemovalEffect(
              repositoryID: repository.id,
              selectionWasRemoved: selectionWasRemoved,
              diskDeletionURL: trashURL
            )
          }
          return .send(.deleteWorktreeApply(worktreeID, repositoryID))
        }
        state.deleteScriptWorktreeIDs.insert(worktree.id)
        return .send(
          .delegate(.runBlockingScript(worktree, repositoryID: repositoryID, kind: .delete, script: script)))

      case .deleteScriptCompleted(let worktreeID, let exitCode, let tabId):
        guard state.deleteScriptWorktreeIDs.contains(worktreeID) else {
          repositoriesLogger.debug(
            "Ignoring deleteScriptCompleted for \(worktreeID): not in deleteScriptWorktreeIDs."
          )
          return .none
        }
        state.deleteScriptWorktreeIDs.remove(worktreeID)
        // Route by recorded intent, not live classification — a
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
        switch exitCode {
        case 0:
          guard let folderIntent, let owningRepo else {
            guard let repositoryID = state.repositoryID(containing: worktreeID) else {
              // Repo vanished between confirmation and script
              // completion (concurrent reload / remove-failed race).
              // If the worktree id follows the folder-synthetic
              // convention and `removingRepositoryIDs` still holds
              // a folder record, drain the batch via
              // `signalFolderRemovalFailure` so sibling targets
              // don't hang forever; only surface the "Delete
              // failed" alert when no folder record exists.
              if let syntheticRepoID = Repository.repositoryID(
                fromFolderWorktreeID: worktreeID
              ), state.removingRepositoryIDs[syntheticRepoID]?.disposition.isFolder == true {
                repositoriesLogger.warning(
                  "Delete script succeeded but repository vanished for folder worktree "
                    + "\(worktreeID); draining batch as failure."
                )
                return signalFolderRemovalFailure(worktreeID: worktreeID, state: &state)
              }
              repositoriesLogger.warning(
                "Delete script succeeded but repository not found for worktree \(worktreeID)"
              )
              state.alert = messageAlert(
                title: "Delete failed",
                message: "The delete script completed successfully, but the worktree could not be found."
                  + " It may have been removed."
              )
              return .none
            }
            return .send(.deleteWorktreeApply(worktreeID, repositoryID))
          }
          if owningRepo.isGitRepository {
            // Kind flipped between confirmation and completion —
            // bail out rather than silently picking a path.
            state.alert = messageAlert(
              title: "Folder is now a git repository",
              message: "Supacode stopped the removal because \(owningRepo.name) became a git "
                + "repository while the delete script was running. Review it and try again."
            )
            return signalFolderRemovalFailure(worktreeID: worktreeID, state: &state)
          }
          let selectionWasRemoved = state.selectedWorktreeID == worktreeID
          let trashURL = folderIntent == .folderTrash ? owningRepo.rootURL : nil
          return folderRemovalEffect(
            repositoryID: owningRepo.id,
            selectionWasRemoved: selectionWasRemoved,
            diskDeletionURL: trashURL
          )
        case nil:
          // User closed the script tab.
          repositoriesLogger.debug(
            "Delete script cancelled or tab closed for worktree \(worktreeID).")
          return signalFolderRemovalFailure(worktreeID: worktreeID, state: &state)
        case let code?:
          // Script failed. Show the standard failure alert AND — for
          // folder removals — signal the aggregator so bulk batches
          // don't hang waiting for this target. Git worktree delete
          // has no batch.
          state.alert = blockingScriptFailureAlert(
            kind: .delete, exitCode: code, worktreeID: worktreeID, tabId: tabId, state: state
          )
          return signalFolderRemovalFailure(worktreeID: worktreeID, state: &state)
        }

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
        state.deletingWorktreeIDs.insert(worktree.id)
        let selectionWasRemoved = state.selectedWorktreeID == worktree.id
        let nextSelection =
          selectionWasRemoved
          ? nextWorktreeID(afterRemoving: worktree, in: repository, state: state)
          : nil
        @Shared(.settingsFile) var settingsFile
        let deleteBranchOnDeleteWorktree = settingsFile.global.deleteBranchOnDeleteWorktree
        return .run { send in
          do {
            _ = try await gitClient.removeWorktree(
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
          state.deletingWorktreeIDs.remove(worktreeID)
          state.deleteScriptWorktreeIDs.remove(worktreeID)
          state.archivingWorktreeIDs.remove(worktreeID)
          state.pendingWorktrees.removeAll { $0.id == worktreeID }
          state.pendingSetupScriptWorktreeIDs.remove(worktreeID)
          state.pendingTerminalFocusWorktreeIDs.remove(worktreeID)
          state.worktreeInfoByID.removeValue(forKey: worktreeID)
          // Drop the worktree from every bucket in its section —
          // the worktree is going away entirely so the bucket it
          // currently lives in doesn't matter.
          state.$sidebar.withLock { sidebar in
            sidebar.removeAnywhere(worktree: worktreeID, in: repositoryID)
          }
          _ = removeWorktree(worktreeID, repositoryID: repositoryID, state: &state)
          let selectionNeedsUpdate = state.selection == .worktree(worktreeID)
          if selectionNeedsUpdate {
            let nextWorktreeID = nextSelection ?? firstAvailableWorktreeID(in: repositoryID, state: state)
            state.selection = nextWorktreeID.map(SidebarSelection.worktree)
          }
        }
        let roots = state.repositories.map(\.rootURL)
        let repositories = state.repositories
        let selectedWorktree = state.worktree(for: state.selectedWorktreeID)
        let selectionChanged = selectionDidChange(
          previousSelectionID: previousSelection,
          previousSelectedWorktree: previousSelectedWorktree,
          selectedWorktreeID: state.selectedWorktreeID,
          selectedWorktree: selectedWorktree
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
        }
        return .none

      case .deleteWorktreeFailed(let message, let worktreeID):
        state.deletingWorktreeIDs.remove(worktreeID)
        state.alert = messageAlert(title: "Unable to delete worktree", message: message)
        return .none

      case .requestDeleteRepository(let repositoryID):
        state.alert = confirmationAlertForRepositoryRemoval(repositoryID: repositoryID, state: state)
        return .none

      case .removeFailedRepository(let repositoryID):
        state.alert = nil
        state.loadFailuresByID.removeValue(forKey: repositoryID)
        state.repositoryRoots.removeAll {
          $0.standardizedFileURL.path(percentEncoded: false) == repositoryID
        }
        return .run { send in
          let loadedPaths = await repositoryPersistence.loadRoots()
          var seen: Set<String> = []
          let rootPaths = loadedPaths.filter { seen.insert($0).inserted }
          let remaining = rootPaths.filter { $0 != repositoryID }
          await repositoryPersistence.saveRoots(remaining)
          await repositoryPersistence.pruneRepositoryConfigs([repositoryID])
          let roots = remaining.map { URL(fileURLWithPath: $0) }
          let (repositories, failures) = await loadRepositoriesData(roots)
          await send(
            .repositoriesLoaded(
              repositories,
              failures: failures,
              roots: roots,
              animated: true
            )
          )
        }
        .cancellable(id: CancelID.load, cancelInFlight: true)

      case .alert(.presented(.confirmDeleteRepository(let repositoryID))):
        guard let repository = state.repositories[id: repositoryID] else {
          return .none
        }
        if state.removingRepositoryIDs[repository.id] != nil {
          return .none
        }
        state.alert = nil
        // Section-level removal — Supacode never nukes a git repo's
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
          // Orphaned completion — every sender seeds the record +
          // batch before signalling, so arriving here means a bug
          // (e.g. future caller skipped setup). Surface it loudly
          // via `reportIssue` so tests fail and release builds emit
          // a warning, and defensively clean up any state the
          // absent terminal would otherwise leave hanging.
          reportIssue(
            """
            repositoryRemovalCompleted: no active batch for \(repositoryID). \
            This indicates an invariant violation — every confirm handler \
            must seed a batch before per-target work fires.
            """
          )
          state.removingRepositoryIDs[repositoryID] = nil
          // Shared cleanup for the two failure-under-orphan paths:
          // clear per-worktree trackers for this repo's folder-synthetic
          // worktree id so `deletingWorktreeIDs` /
          // `deleteScriptWorktreeIDs` entries can't leak beyond the
          // failed attempt. Only the folder-synthetic id is ever
          // populated by the folder removal pipeline; narrow the
          // cleanup to it so a future caller passing a git repo id
          // here can't accidentally clobber in-flight worktree-delete
          // trackers for sibling git worktrees.
          let orphanFolderWorktreeID = Repository.folderWorktreeID(
            for: URL(fileURLWithPath: repositoryID)
          )
          switch outcome {
          case .success:
            return .send(
              .repositoriesRemoved([repositoryID], selectionWasRemoved: selectionWasRemoved))
          case .failureSilent:
            state.deletingWorktreeIDs.remove(orphanFolderWorktreeID)
            state.deleteScriptWorktreeIDs.remove(orphanFolderWorktreeID)
            return .none
          case .failureWithMessage(let message):
            state.deletingWorktreeIDs.remove(orphanFolderWorktreeID)
            state.deleteScriptWorktreeIDs.remove(orphanFolderWorktreeID)
            state.alert = messageAlert(
              title: "Delete from disk failed", message: message
            )
            return .none
          }
        }
        let batchID = record.batchID
        batch.pending.remove(repositoryID)
        batch.selectionWasRemoved = batch.selectionWasRemoved || selectionWasRemoved
        // Shared failure cleanup — drain the target from the batch
        // without removing the repo from state. Clears the record
        // AND the folder-synthetic per-worktree trackers —
        // `deletingWorktreeIDs` / `deleteScriptWorktreeIDs`
        // entries seeded by the empty-script folder branch (or the
        // blocking-script run) would otherwise leave the row stuck
        // in `.deleting` forever. Scoped to the synthetic folder
        // worktree id because only folder dispositions ever reach
        // a failure completion (`.gitRepositoryUnlink` hardcodes
        // `.success` at confirm time); clearing every worktree of
        // the repo would reach too far if a future caller extends
        // this path to git repos.
        let folderWorktreeIDForFailure: Worktree.ID? =
          record.disposition.isFolder
          ? Repository.folderWorktreeID(for: URL(fileURLWithPath: repositoryID))
          : nil
        switch outcome {
        case .success:
          batch.succeeded.append(repositoryID)
        // `.repositoriesRemoved` clears `removingRepositoryIDs`
        // for the successful targets as part of the terminal —
        // leave the record in place so the UI keeps showing the
        // "removing" indicator until then.
        case .failureSilent:
          state.removingRepositoryIDs[repositoryID] = nil
          if let folderWorktreeIDForFailure {
            state.deletingWorktreeIDs.remove(folderWorktreeIDForFailure)
            state.deleteScriptWorktreeIDs.remove(folderWorktreeIDForFailure)
          }
          batch.hasSilentFailure = true
        case .failureWithMessage(let message):
          state.removingRepositoryIDs[repositoryID] = nil
          if let folderWorktreeIDForFailure {
            state.deletingWorktreeIDs.remove(folderWorktreeIDForFailure)
            state.deleteScriptWorktreeIDs.remove(folderWorktreeIDForFailure)
          }
          batch.failureMessagesByRepositoryID[repositoryID] = message
        }
        if batch.pending.isEmpty {
          state.activeRemovalBatches[batchID] = nil
          // Consolidated failure alert — when any target in the
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
                let name = state.repositories[id: id]?.name ?? id
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
          guard !batch.succeeded.isEmpty else { return .none }
          return .send(
            .repositoriesRemoved(
              batch.succeeded, selectionWasRemoved: batch.selectionWasRemoved))
        }
        state.activeRemovalBatches[batchID] = batch
        return .none

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
          !idSet.contains($0.standardizedFileURL.path(percentEncoded: false))
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
            // second step those entries pile up forever —
            // especially visible for folder repos that users add +
            // remove while exploring.
            await repositoryPersistence.saveRoots(pathsToPersist)
            await repositoryPersistence.pruneRepositoryConfigs(removedIDs)
          }
          .cancellable(id: CancelID.persistRoots, cancelInFlight: true)
        )

      case .pinWorktree(let worktreeID):
        // Main worktrees never appear in any sidebar bucket (the
        // seed pass skips them), so pinning one is a no-op.
        guard let worktree = state.worktree(for: worktreeID),
          let repositoryID = state.repositoryID(containing: worktreeID),
          let repository = state.repositories[id: repositoryID]
        else {
          return .none
        }
        // Folder-synthetic worktrees pass `isMainWorktree` by
        // geometry. Surface the deeplink-equivalent alert instead
        // of silently no-op-ing for folders; for git mains the
        // silent skip is still correct (main-worktree pinning is
        // invalid by design).
        if !repository.isGitRepository {
          state.alert = folderIncompatibleAlert(action: .pin)
          return .none
        }
        if state.isMainWorktree(worktree) {
          return .none
        }
        analyticsClient.capture("worktree_pinned", nil)
        state.$sidebar.withLock { sidebar in
          // The seed invariant puts every non-main worktree into
          // either `.pinned` or `.unpinned`. A second click on an
          // already-pinned row reorders it to the top.
          let from = sidebar.currentBucket(of: worktreeID, in: repositoryID) ?? .unpinned
          sidebar.move(
            worktree: worktreeID,
            in: repositoryID,
            from: from,
            to: .pinned,
            position: 0
          )
        }
        return .none

      case .unpinWorktree(let worktreeID):
        guard let repositoryID = state.repositoryID(containing: worktreeID),
          let repository = state.repositories[id: repositoryID]
        else {
          return .none
        }
        if !repository.isGitRepository {
          state.alert = folderIncompatibleAlert(action: .unpin)
          return .none
        }
        analyticsClient.capture("worktree_unpinned", nil)
        state.$sidebar.withLock { sidebar in
          sidebar.move(
            worktree: worktreeID,
            in: repositoryID,
            from: .pinned,
            to: .unpinned,
            position: 0
          )
        }
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
          return .run { send in
            try? await ContinuousClock().sleep(for: .seconds(2.5))
            await send(.dismissToast)
          }
          .cancellable(id: CancelID.toastAutoDismiss, cancelInFlight: true)
        }

      case .dismissToast:
        state.statusToast = nil
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
        return .run { send in
          try? await ContinuousClock().sleep(for: .seconds(2))
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

      case .worktreeNotificationReceived(let worktreeID):
        guard let repositoryID = state.repositoryID(containing: worktreeID),
          let repository = state.repositories[id: repositoryID],
          let worktree = repository.worktrees[id: worktreeID]
        else {
          return .none
        }
        if state.isWorktreeArchived(worktree.id) {
          return .none
        }

        if state.moveNotifiedWorktreeToTop, !state.isMainWorktree(worktree), !state.isWorktreePinned(worktree) {
          let reordered = reorderedUnpinnedWorktreeIDs(
            for: worktreeID,
            in: repository,
            state: state
          )
          // Only reorder when the bumped worktree currently lives in
          // (or is about to land in) the unpinned bucket — pinned
          // rows live in `.pinned` and should not be perturbed by
          // notification arrivals on a sibling.
          let currentUnpinned = Array(
            state.sidebar.sections[repositoryID]?.buckets[.unpinned]?.items.keys ?? []
          )
          if currentUnpinned != reordered {
            withAnimation(.snappy(duration: 0.2)) {
              state.$sidebar.withLock { sidebar in
                sidebar.reorder(bucket: .unpinned, in: repositoryID, to: reordered)
              }
            }
          }
        }

        return .none

      case .worktreeInfoEvent(let event):
        switch event {
        case .branchChanged(let worktreeID):
          guard let worktree = state.worktree(for: worktreeID) else {
            return .none
          }
          let worktreeURL = worktree.workingDirectory
          let gitClient = gitClient
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
          let gitClient = gitClient
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
              queuePullRequestRefresh(
                repositoryID: repositoryID,
                repositoryRootURL: repositoryRootURL,
                worktreeIDs: worktreeIDs,
                refreshesByRepositoryID: &state.queuedPullRequestRefreshByRepositoryID
              )
              return .none
            }
            state.inFlightPullRequestRefreshRepositoryIDs.insert(repositoryID)
            return refreshRepositoryPullRequests(
              repositoryID: repositoryID,
              repositoryRootURL: repositoryRootURL,
              worktrees: worktrees,
              branches: branches
            )
          case .unknown:
            queuePullRequestRefresh(
              repositoryID: repositoryID,
              repositoryRootURL: repositoryRootURL,
              worktreeIDs: worktreeIDs,
              refreshesByRepositoryID: &state.pendingPullRequestRefreshByRepositoryID
            )
            return .send(.refreshGithubIntegrationAvailability)
          case .checking:
            queuePullRequestRefresh(
              repositoryID: repositoryID,
              repositoryRootURL: repositoryRootURL,
              worktreeIDs: worktreeIDs,
              refreshesByRepositoryID: &state.pendingPullRequestRefreshByRepositoryID
            )
            return .none
          case .unavailable:
            queuePullRequestRefresh(
              repositoryID: repositoryID,
              repositoryRootURL: repositoryRootURL,
              worktreeIDs: worktreeIDs,
              refreshesByRepositoryID: &state.pendingPullRequestRefreshByRepositoryID
            )
            return .none
          case .disabled:
            return .none
          }
        }

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
            queuePullRequestRefresh(
              repositoryID: repositoryID,
              repositoryRootURL: queued.repositoryRootURL,
              worktreeIDs: queued.worktreeIDs,
              refreshesByRepositoryID: &state.pendingPullRequestRefreshByRepositoryID
            )
          }
          state.queuedPullRequestRefreshByRepositoryID.removeAll()
          state.inFlightPullRequestRefreshRepositoryIDs.removeAll()
          return .run { send in
            while !Task.isCancelled {
              try? await ContinuousClock().sleep(for: githubIntegrationRecoveryInterval)
              guard !Task.isCancelled else {
                return
              }
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
        updateWorktreeName(worktreeID, name: name, state: &state)
        return .none

      case .worktreeLineChangesLoaded(let worktreeID, let added, let removed):
        updateWorktreeLineChanges(
          worktreeID: worktreeID,
          added: added,
          removed: removed,
          state: &state
        )
        return .none

      case .repositoryPullRequestsLoaded(let repositoryID, let pullRequestsByWorktreeID):
        guard let repository = state.repositories[id: repositoryID] else {
          return .none
        }
        var archiveWorktreeIDs: [Worktree.ID] = []
        var deleteWorktreeIDs: [Worktree.ID] = []
        for worktreeID in pullRequestsByWorktreeID.keys.sorted() {
          guard let worktree = repository.worktrees[id: worktreeID] else {
            continue
          }
          let pullRequest = pullRequestsByWorktreeID[worktreeID] ?? nil
          let previousPullRequest = state.worktreeInfoByID[worktreeID]?.pullRequest
          guard previousPullRequest != pullRequest else {
            continue
          }
          let previousMerged = previousPullRequest?.state == "MERGED"
          let nextMerged = pullRequest?.state == "MERGED"
          updateWorktreePullRequest(
            worktreeID: worktreeID,
            pullRequest: pullRequest,
            state: &state
          )
          if let mergedAction = state.mergedWorktreeAction,
            !previousMerged,
            nextMerged,
            !state.isMainWorktree(worktree),
            !state.isWorktreeArchived(worktreeID),
            !state.deletingWorktreeIDs.contains(worktreeID),
            !state.deleteScriptWorktreeIDs.contains(worktreeID)
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
          archiveWorktreeIDs.map { .send(.archiveWorktreeConfirmed($0, repositoryID)) }
          + deleteWorktreeIDs.map { .send(.deleteSidebarItemConfirmed($0, repositoryID)) }
        guard !effects.isEmpty else {
          return .none
        }
        return .merge(effects)

      case .pullRequestAction(let worktreeID, let action):
        guard let worktree = state.worktree(for: worktreeID),
          let repositoryID = state.repositoryID(containing: worktreeID),
          let repository = state.repositories[id: repositoryID],
          let pullRequest = state.worktreeInfo(for: worktreeID)?.pullRequest
        else {
          return .send(
            .presentAlert(
              title: "Pull request not available",
              message: "Supacode could not find a pull request for this worktree."
            )
          )
        }
        let repoRoot = worktree.repositoryRootURL
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
            @Shared(.repositorySettings(repoRoot)) var repositorySettings
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
          return .merge(
            .cancel(id: CancelID.githubIntegrationRecovery),
            .send(.refreshGithubIntegrationAvailability)
          )
        }
        state.githubIntegrationAvailability = .disabled
        state.pendingPullRequestRefreshByRepositoryID.removeAll()
        state.queuedPullRequestRefreshByRepositoryID.removeAll()
        state.inFlightPullRequestRefreshRepositoryIDs.removeAll()
        let worktreeIDs = Array(state.worktreeInfoByID.keys)
        for worktreeID in worktreeIDs {
          updateWorktreePullRequest(
            worktreeID: worktreeID,
            pullRequest: nil,
            state: &state
          )
        }
        return .merge(
          .cancel(id: CancelID.githubIntegrationAvailability),
          .cancel(id: CancelID.githubIntegrationRecovery)
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
        // state — a bug in a future archive path, a migration
        // regression, or hand-edited sidebar.json — we both flag
        // the invariant breach AND purge the stray entry from
        // `sidebar.archivedWorktrees`, so the next reload doesn't
        // re-fire `reportIssue` forever.
        var strayFolderArchives: [(Worktree.ID, Repository.ID)] = []
        for archived in state.sidebar.archivedWorktrees
        where Repository.isFolderWorktreeID(archived.worktreeID) {
          strayFolderArchives.append((archived.worktreeID, archived.repositoryID))
        }
        if !strayFolderArchives.isEmpty {
          for (worktreeID, _) in strayFolderArchives {
            reportIssue(
              """
              Auto-delete encountered folder-synthetic archived worktree \(worktreeID) — \
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
          if Repository.isFolderWorktreeID(worktreeID) {
            // Already purged above — defensive skip.
            continue
          }
          guard !state.deletingWorktreeIDs.contains(worktreeID),
            !state.deleteScriptWorktreeIDs.contains(worktreeID),
            !state.archivingWorktreeIDs.contains(worktreeID)
          else { continue }
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
        let section = state.sidebar.sections[repositoryID]
        let storedTitle = section?.title ?? ""
        let storedColor = section?.color
        state.repositoryCustomization = RepositoryCustomizationFeature.State(
          repositoryID: repositoryID,
          defaultName: repository.name,
          title: storedTitle,
          color: storedColor,
          customColor: storedColor?.color ?? .accentColor
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
      }
    }
    .ifLet(\.$worktreeCreationPrompt, action: \.worktreeCreationPrompt) {
      WorktreeCreationPromptFeature()
    }
    .ifLet(\.$repositoryCustomization, action: \.repositoryCustomization) {
      RepositoryCustomizationFeature()
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
      for root in roots {
        _ = try? await gitClient.pruneWorktrees(root)
      }
      let (repositories, failures) = await loadRepositoriesData(roots)
      await send(
        .repositoriesLoaded(
          repositories,
          failures: failures,
          roots: roots,
          animated: animated
        )
      )
    }
    .cancellable(id: CancelID.load, cancelInFlight: true)
  }

  private struct WorktreesFetchResult: Sendable {
    let root: URL
    let isGitRepository: Bool
    let worktrees: [Worktree]?
    let errorMessage: String?
  }

  private func loadRepositoriesData(_ roots: [URL]) async -> ([Repository], [LoadFailure]) {
    let fetchResults = await withTaskGroup(of: WorktreesFetchResult.self) { group in
      for root in roots {
        let gitClient = self.gitClient
        group.addTask {
          // Directory-existence check first — if the root is gone
          // (user trashed it from Finder while Supacode was
          // running, external tooling removed it, the volume is
          // unmounted), surface a load failure so the sidebar
          // shows the error row. Otherwise `gitClient.isGitRepository`
          // returns `false` for the missing path and the loader
          // silently synthesizes an empty folder repository, which
          // hides the real problem from the user. Routed through
          // the dependency so tests with fake `/tmp/...` paths
          // don't trip the check — they override it explicitly.
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
          // Classify through the git client so tests can override
          // without touching the filesystem — non-git folders skip
          // the worktrees subprocess entirely.
          let isGit = await gitClient.isGitRepository(root)
          guard isGit else {
            return WorktreesFetchResult(
              root: root,
              isGitRepository: false,
              worktrees: [],
              errorMessage: nil
            )
          }
          do {
            let worktrees = try await gitClient.worktrees(root)
            return WorktreesFetchResult(
              root: root,
              isGitRepository: true,
              worktrees: worktrees,
              errorMessage: nil
            )
          } catch {
            return WorktreesFetchResult(
              root: root,
              isGitRepository: true,
              worktrees: nil,
              errorMessage: error.localizedDescription
            )
          }
        }
      }

      var resultsByRootID: [Repository.ID: WorktreesFetchResult] = [:]
      for await result in group {
        let rootID = result.root.standardizedFileURL.path(percentEncoded: false)
        resultsByRootID[rootID] = result
      }
      return resultsByRootID
    }

    var loaded: [Repository] = []
    var failures: [LoadFailure] = []
    for root in roots {
      let normalizedRoot = root.standardizedFileURL
      let rootID = normalizedRoot.path(percentEncoded: false)
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
          failures.append(
            LoadFailure(
              rootID: rootID,
              message: result.errorMessage ?? "Unknown error"
            )
          )
        }
      } else if let errorMessage = result.errorMessage {
        // Non-git root with an error — classifier couldn't open
        // the directory (missing / unmounted / unreadable).
        // Route through the same `LoadFailure` pipeline git
        // repos use so the sidebar shows the error row.
        failures.append(
          LoadFailure(rootID: rootID, message: errorMessage)
        )
      } else {
        // Folder repository — synthesize a single main-like worktree
        // so the existing sidebar selection + terminal plumbing keeps
        // working without new entity types.
        let synthetic = Worktree(
          id: Repository.folderWorktreeID(for: normalizedRoot),
          name: name,
          detail: "",
          workingDirectory: normalizedRoot,
          repositoryRootURL: normalizedRoot
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
    return (loaded, failures)
  }

  private func applyRepositories(
    _ repositories: [Repository],
    roots: [URL],
    shouldPruneArchivedWorktreeIDs: Bool,
    state: inout State,
    animated: Bool
  ) -> ApplyRepositoriesResult {
    let previousCounts = Dictionary(
      uniqueKeysWithValues: state.repositories.map { ($0.id, $0.worktrees.count) }
    )
    let repositoryIDs = Set(repositories.map(\.id))
    let newCounts = Dictionary(
      uniqueKeysWithValues: repositories.map { ($0.id, $0.worktrees.count) }
    )
    var addedCounts: [Repository.ID: Int] = [:]
    for (id, newCount) in newCounts {
      let oldCount = previousCounts[id] ?? 0
      let added = newCount - oldCount
      if added > 0 {
        addedCounts[id] = added
      }
    }
    let filteredPendingWorktrees = state.pendingWorktrees.filter { pending in
      guard repositoryIDs.contains(pending.repositoryID) else { return false }
      guard let remaining = addedCounts[pending.repositoryID], remaining > 0 else { return true }
      addedCounts[pending.repositoryID] = remaining - 1
      return false
    }
    let availableWorktreeIDs = Set(repositories.flatMap { $0.worktrees.map(\.id) })
    let filteredDeletingIDs = state.deletingWorktreeIDs.intersection(availableWorktreeIDs)
    let filteredDeleteScriptIDs = state.deleteScriptWorktreeIDs
    let filteredSetupScriptIDs = state.pendingSetupScriptWorktreeIDs.filter {
      availableWorktreeIDs.contains($0)
    }
    let filteredFocusIDs = state.pendingTerminalFocusWorktreeIDs.filter {
      availableWorktreeIDs.contains($0)
    }
    let filteredRunningScripts = state.runningScriptsByWorktreeID.filter {
      availableWorktreeIDs.contains($0.key)
    }
    let filteredArchivingIDs = state.archivingWorktreeIDs
    let filteredWorktreeInfo = state.worktreeInfoByID.filter {
      availableWorktreeIDs.contains($0.key)
    }
    let (filteredRemovingRepositoryIDs, filteredActiveRemovalBatches) =
      prunedRemovalTrackers(state: state, availableRepoIDs: repositoryIDs)
    let identifiedRepositories = IdentifiedArray(uniqueElements: repositories)
    if animated {
      withAnimation {
        state.repositories = identifiedRepositories
        state.pendingWorktrees = filteredPendingWorktrees
        state.deletingWorktreeIDs = filteredDeletingIDs
        state.deleteScriptWorktreeIDs = filteredDeleteScriptIDs
        state.pendingSetupScriptWorktreeIDs = filteredSetupScriptIDs
        state.pendingTerminalFocusWorktreeIDs = filteredFocusIDs
        state.runningScriptsByWorktreeID = filteredRunningScripts

        state.archivingWorktreeIDs = filteredArchivingIDs
        state.worktreeInfoByID = filteredWorktreeInfo
        state.removingRepositoryIDs = filteredRemovingRepositoryIDs
        state.activeRemovalBatches = filteredActiveRemovalBatches
      }
    } else {
      state.repositories = identifiedRepositories
      state.pendingWorktrees = filteredPendingWorktrees
      state.deletingWorktreeIDs = filteredDeletingIDs
      state.deleteScriptWorktreeIDs = filteredDeleteScriptIDs
      state.pendingSetupScriptWorktreeIDs = filteredSetupScriptIDs
      state.pendingTerminalFocusWorktreeIDs = filteredFocusIDs
      state.runningScriptsByWorktreeID = filteredRunningScripts
      state.archivingWorktreeIDs = filteredArchivingIDs
      state.worktreeInfoByID = filteredWorktreeInfo
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
    reconcileSidebarState(
      roots: roots,
      state: &state,
      pruneLivenessAgainstRoster: state.isInitialLoadComplete
    )
    let didPruneArchivedWorktreeIDs =
      shouldPruneArchivedWorktreeIDs
      ? pruneArchivedWorktreeIDs(availableWorktreeIDs: availableWorktreeIDs, state: &state)
      : false
    if !state.isShowingArchivedWorktrees, !isSelectionValid(state.selectedWorktreeID, state: state) {
      state.selection = nil
    }
    if state.shouldRestoreLastFocusedWorktree {
      state.shouldRestoreLastFocusedWorktree = false
      if state.selection == nil,
        isSelectionValid(state.sidebar.focusedWorktreeID, state: state)
      {
        state.selection = state.sidebar.focusedWorktreeID.map(SidebarSelection.worktree)
      }
    }
    if state.selection == nil, state.shouldSelectFirstAfterReload {
      state.selection = firstAvailableWorktreeID(from: repositories, state: state)
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

  var effectiveSidebarSelectedRows: [SidebarItemModel] {
    let selectedRows = orderedSidebarItems().filter { sidebarSelectedWorktreeIDs.contains($0.id) }
    return selectedRows.isEmpty ? (selectedRow(for: selectedWorktreeID).map { [$0] } ?? []) : selectedRows
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

  var sidebarSelections: Set<SidebarSelection> {
    guard !isShowingArchivedWorktrees else {
      return [.archivedWorktrees]
    }
    var selections = Set(sidebarSelectedWorktreeIDs.map(SidebarSelection.worktree))
    if let selectedWorktreeID {
      selections.insert(.worktree(selectedWorktreeID))
    }
    return selections
  }

  func worktreeID(byOffset offset: Int) -> Worktree.ID? {
    let rows = orderedSidebarItems(includingRepositoryIDs: expandedRepositoryIDs)
    guard !rows.isEmpty else { return nil }
    if let currentID = selectedWorktreeID,
      let currentIndex = rows.firstIndex(where: { $0.id == currentID })
    {
      return rows[(currentIndex + offset + rows.count) % rows.count].id
    }
    return rows[offset > 0 ? 0 : rows.count - 1].id
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

  func worktreeInfo(for worktreeID: Worktree.ID) -> WorktreeInfoEntry? {
    worktreeInfoByID[worktreeID]
  }

  func worktreesForInfoWatcher() -> [Worktree] {
    // Folder repositories are non-git — skip them so the watcher
    // doesn't attempt to observe HEAD / diff stats on a directory
    // without a `.git` path.
    let worktrees =
      repositories
      .filter(\.isGitRepository)
      .flatMap(\.worktrees)
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
    if let repository = repositoryForWorktreeCreation(self) {
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
  /// ordered deterministically by script ID. The tint travels alongside
  /// the running script ID so the color resolves correctly even when
  /// the worktree belongs to a repository other than the selected one.
  func runningScriptColors(for worktreeID: Worktree.ID) -> [TerminalTabTintColor] {
    guard let tintsByID = runningScriptsByWorktreeID[worktreeID] else { return [] }
    return tintsByID.sorted(by: { $0.key < $1.key }).map(\.value)
  }

  func pendingWorktree(for id: Worktree.ID?) -> PendingWorktree? {
    guard let id else { return nil }
    return pendingWorktrees.first(where: { $0.id == id })
  }

  func shouldFocusTerminal(for worktreeID: Worktree.ID) -> Bool {
    pendingTerminalFocusWorktreeIDs.contains(worktreeID)
  }

  private func makePendingSidebarItem(_ pending: PendingWorktree) -> SidebarItemModel {
    let status: SidebarItemModel.Status =
      removingRepositoryIDs[pending.repositoryID] != nil
      ? .deleting(inTerminal: false)
      : .pending
    // Folders cannot have pending worktrees — creation is gated on
    // `isGitRepository` before reaching `.createWorktreeStream`.
    return SidebarItemModel(
      id: pending.id,
      repositoryID: pending.repositoryID,
      kind: .git,
      name: pending.progress.worktreeName ?? "Creating…",
      detail: pending.progress.worktreeName ?? "",
      info: worktreeInfo(for: pending.id),
      isPinned: false,
      isMainWorktree: false,
      status: status
    )
  }

  private func makeSidebarItem(
    _ worktree: Worktree,
    repositoryID: Repository.ID,
    kind: SidebarItemModel.Kind,
    isPinned: Bool,
    isMainWorktree: Bool
  ) -> SidebarItemModel {
    // `deleteScriptWorktreeIDs` wins over `removingRepositoryIDs` so
    // a folder delete with a blocking script shows the terminal
    // indicator and stays clickable (matching the worktree flow),
    // rather than being immediately masked by the repo-level
    // "removing" flag that the folder pipeline sets up front to
    // carry the removal intent.
    let status: SidebarItemModel.Status =
      if deleteScriptWorktreeIDs.contains(worktree.id) {
        .deleting(inTerminal: true)
      } else if removingRepositoryIDs[repositoryID] != nil
        || deletingWorktreeIDs.contains(worktree.id)
      {
        .deleting(inTerminal: false)
      } else if archivingWorktreeIDs.contains(worktree.id) {
        .archiving
      } else {
        .idle
      }
    return SidebarItemModel(
      id: worktree.id,
      repositoryID: repositoryID,
      kind: kind,
      name: worktree.name,
      detail: worktree.detail,
      info: worktreeInfo(for: worktree.id),
      isPinned: isPinned,
      isMainWorktree: isMainWorktree,
      status: status
    )
  }

  func selectedRow(for id: Worktree.ID?) -> SidebarItemModel? {
    guard let id else { return nil }
    if isWorktreeArchived(id) {
      return nil
    }
    if let pending = pendingWorktree(for: id) {
      return makePendingSidebarItem(pending)
    }
    for repository in repositories {
      if let worktree = repository.worktrees[id: id] {
        return makeSidebarItem(
          worktree,
          repositoryID: repository.id,
          kind: repository.isGitRepository ? .git : .folder,
          isPinned: isWorktreePinned(worktree),
          isMainWorktree: isMainWorktree(worktree)
        )
      }
    }
    return nil
  }

  func repositoryName(for id: Repository.ID) -> String? {
    repositories[id: id]?.name
  }

  func orderedRepositoryRoots() -> [URL] {
    let rootsByID = Dictionary(
      uniqueKeysWithValues: repositoryRoots.map {
        ($0.standardizedFileURL.path(percentEncoded: false), $0.standardizedFileURL)
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
      let id = rootURL.standardizedFileURL.path(percentEncoded: false)
      if seen.insert(id).inserted {
        ordered.append(rootURL.standardizedFileURL)
      }
    }
    if ordered.isEmpty {
      ordered = repositories.map(\.rootURL)
    }
    return ordered
  }

  func orderedRepositoryIDs() -> [Repository.ID] {
    orderedRepositoryRoots().map { $0.standardizedFileURL.path(percentEncoded: false) }
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

  func isMainWorktree(_ worktree: Worktree) -> Bool {
    worktree.workingDirectory.standardizedFileURL == worktree.repositoryRootURL.standardizedFileURL
  }

  func isWorktreeMerged(_ worktree: Worktree) -> Bool {
    worktreeInfoByID[worktree.id]?.pullRequest?.state == "MERGED"
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
    if !repository.isGitRepository, deleteScriptWorktreeIDs.contains(folderWorktreeID) {
      return false
    }
    return true
  }

  func sidebarItemSections(in repository: Repository) -> SidebarItemSections {
    let kind: SidebarItemModel.Kind = repository.isGitRepository ? .git : .folder
    let mainWorktree = repository.worktrees.first(where: { isMainWorktree($0) })
    let pinnedWorktrees = orderedPinnedWorktrees(in: repository)
    let unpinnedWorktrees = orderedUnpinnedWorktrees(in: repository)
    let pendingEntries = pendingWorktrees.filter { $0.repositoryID == repository.id }
    let mainRow: SidebarItemModel? =
      if let mainWorktree, !isWorktreeArchived(mainWorktree.id) {
        makeSidebarItem(
          mainWorktree,
          repositoryID: repository.id,
          kind: kind,
          isPinned: false,
          isMainWorktree: true
        )
      } else {
        nil
      }
    var pinnedRows: [SidebarItemModel] = []
    for worktree in pinnedWorktrees {
      pinnedRows.append(
        makeSidebarItem(
          worktree,
          repositoryID: repository.id,
          kind: kind,
          isPinned: true,
          isMainWorktree: false
        )
      )
    }
    var pendingRows: [SidebarItemModel] = []
    for pending in pendingEntries {
      pendingRows.append(makePendingSidebarItem(pending))
    }
    var unpinnedRows: [SidebarItemModel] = []
    for worktree in unpinnedWorktrees {
      unpinnedRows.append(
        makeSidebarItem(
          worktree,
          repositoryID: repository.id,
          kind: kind,
          isPinned: false,
          isMainWorktree: false
        )
      )
    }
    // Archived worktrees with a running delete script should be
    // visible in the sidebar so the terminal tab is accessible.
    let archivedSet = archivedWorktreeIDSet
    let unpinnedIDSet = Set(unpinnedWorktrees.map(\.id))
    for worktree in repository.worktrees {
      guard archivedSet.contains(worktree.id),
        deleteScriptWorktreeIDs.contains(worktree.id),
        !unpinnedIDSet.contains(worktree.id)
      else { continue }
      unpinnedRows.append(
        makeSidebarItem(
          worktree,
          repositoryID: repository.id,
          kind: kind,
          isPinned: false,
          isMainWorktree: false
        )
      )
    }
    return SidebarItemSections(
      main: mainRow,
      pinned: pinnedRows,
      pending: pendingRows,
      unpinned: unpinnedRows
    )
  }

  func sidebarItems(in repository: Repository) -> [SidebarItemModel] {
    let sections = sidebarItemSections(in: repository)
    return sections.allRows
  }

  func orderedSidebarItems() -> [SidebarItemModel] {
    orderedSidebarItems(includingRepositoryIDs: Set(repositories.map(\.id)))
  }

  func orderedSidebarItems(includingRepositoryIDs: Set<Repository.ID>) -> [SidebarItemModel] {
    let repositoriesByID = Dictionary(uniqueKeysWithValues: repositories.map { ($0.id, $0) })
    return orderedRepositoryIDs()
      .filter { includingRepositoryIDs.contains($0) }
      .compactMap { repositoriesByID[$0] }
      .flatMap { sidebarItems(in: $0) }
  }
}

struct SidebarItemSections {
  let main: SidebarItemModel?
  let pinned: [SidebarItemModel]
  let pending: [SidebarItemModel]
  let unpinned: [SidebarItemModel]

  var allRows: [SidebarItemModel] {
    var rows: [SidebarItemModel] = []
    if let main {
      rows.append(main)
    }
    rows.append(contentsOf: pinned)
    rows.append(contentsOf: pending)
    rows.append(contentsOf: unpinned)
    return rows
  }
}

private struct FailedWorktreeCleanup {
  let didRemoveWorktree: Bool
  let worktree: Worktree?
}

private func removePendingWorktree(_ id: String, state: inout RepositoriesFeature.State) {
  state.pendingWorktrees.removeAll { $0.id == id }
}

private func updatePendingWorktreeProgress(
  _ id: String,
  progress: WorktreeCreationProgress,
  state: inout RepositoriesFeature.State
) {
  guard let index = state.pendingWorktrees.firstIndex(where: { $0.id == id }) else {
    return
  }
  state.pendingWorktrees[index].progress = progress
}

private func insertWorktree(
  _ worktree: Worktree,
  repositoryID: Repository.ID,
  state: inout RepositoriesFeature.State
) {
  guard let index = state.repositories.index(id: repositoryID) else { return }
  let repository = state.repositories[index]
  if repository.worktrees[id: worktree.id] != nil {
    return
  }
  var worktrees = repository.worktrees
  worktrees.insert(worktree, at: 0)
  state.repositories[index] = Repository(
    id: repository.id,
    rootURL: repository.rootURL,
    name: repository.name,
    worktrees: worktrees
  )
}

@discardableResult
private func removeWorktree(
  _ worktreeID: Worktree.ID,
  repositoryID: Repository.ID,
  state: inout RepositoriesFeature.State
) -> Bool {
  guard let index = state.repositories.index(id: repositoryID) else { return false }
  let repository = state.repositories[index]
  guard repository.worktrees[id: worktreeID] != nil else { return false }
  var worktrees = repository.worktrees
  worktrees.remove(id: worktreeID)
  state.repositories[index] = Repository(
    id: repository.id,
    rootURL: repository.rootURL,
    name: repository.name,
    worktrees: worktrees
  )
  return true
}

private func cleanupFailedWorktree(
  repositoryID: Repository.ID,
  name: String?,
  baseDirectory: URL,
  state: inout RepositoriesFeature.State
) -> FailedWorktreeCleanup {
  guard let name, !name.isEmpty else {
    return FailedWorktreeCleanup(didRemoveWorktree: false, worktree: nil)
  }
  let repositoryRootURL = URL(fileURLWithPath: repositoryID).standardizedFileURL
  let normalizedBaseDirectory = baseDirectory.standardizedFileURL
  let worktreeURL =
    normalizedBaseDirectory
    .appending(path: name, directoryHint: .isDirectory)
    .standardizedFileURL
  guard isPathInsideBaseDirectory(worktreeURL, baseDirectory: normalizedBaseDirectory) else {
    return FailedWorktreeCleanup(didRemoveWorktree: false, worktree: nil)
  }
  let worktreeID = worktreeURL.path(percentEncoded: false)
  let worktree =
    state.repositories[id: repositoryID]?.worktrees[id: worktreeID]
    ?? Worktree(
      id: worktreeID,
      name: name,
      detail: "",
      workingDirectory: worktreeURL,
      repositoryRootURL: repositoryRootURL
    )
  let cleanup = cleanupWorktreeState(
    worktreeID,
    repositoryID: repositoryID,
    state: &state
  )
  return FailedWorktreeCleanup(
    didRemoveWorktree: cleanup.didRemoveWorktree,
    worktree: worktree
  )
}

private func isPathInsideBaseDirectory(_ path: URL, baseDirectory: URL) -> Bool {
  let normalizedPath = path.standardizedFileURL.pathComponents
  let normalizedBase = baseDirectory.standardizedFileURL.pathComponents
  guard normalizedPath.count >= normalizedBase.count else {
    return false
  }
  return Array(normalizedPath.prefix(normalizedBase.count)) == normalizedBase
}

private struct WorktreeCleanupStateResult {
  let didRemoveWorktree: Bool
}

private func cleanupWorktreeState(
  _ worktreeID: Worktree.ID,
  repositoryID: Repository.ID,
  state: inout RepositoriesFeature.State
) -> WorktreeCleanupStateResult {
  let didRemoveWorktree = removeWorktree(worktreeID, repositoryID: repositoryID, state: &state)
  state.pendingWorktrees.removeAll { $0.id == worktreeID }
  state.pendingSetupScriptWorktreeIDs.remove(worktreeID)
  state.pendingTerminalFocusWorktreeIDs.remove(worktreeID)
  state.archivingWorktreeIDs.remove(worktreeID)
  state.deleteScriptWorktreeIDs.remove(worktreeID)
  state.deletingWorktreeIDs.remove(worktreeID)
  state.worktreeInfoByID.removeValue(forKey: worktreeID)
  // Drop the worktree from every bucket in its section — a failed
  // worktree creation is going away entirely so the bucket it
  // currently lives in doesn't matter.
  state.$sidebar.withLock { sidebar in
    sidebar.removeAnywhere(worktree: worktreeID, in: repositoryID)
  }
  return WorktreeCleanupStateResult(didRemoveWorktree: didRemoveWorktree)
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
  copyIgnored: Bool,
  copyUntracked: Bool,
  baseRef: String
) -> String {
  let baseDir = baseDirectoryURL.path(percentEncoded: false)
  var parts = ["wt", "--base-dir", baseDir, "sw"]
  if copyIgnored {
    parts.append("--copy-ignored")
  }
  if copyUntracked {
    parts.append("--copy-untracked")
  }
  if !baseRef.isEmpty {
    parts.append("--from")
    parts.append(baseRef)
  }
  if copyIgnored || copyUntracked {
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

private func updateWorktreeName(
  _ worktreeID: Worktree.ID,
  name: String,
  state: inout RepositoriesFeature.State
) {
  for index in state.repositories.indices {
    var repository = state.repositories[index]
    guard let worktreeIndex = repository.worktrees.index(id: worktreeID) else {
      continue
    }
    let worktree = repository.worktrees[worktreeIndex]
    guard worktree.name != name else {
      return
    }
    var worktrees = repository.worktrees
    worktrees[id: worktreeID] = Worktree(
      id: worktree.id,
      name: name,
      detail: worktree.detail,
      workingDirectory: worktree.workingDirectory,
      repositoryRootURL: worktree.repositoryRootURL,
      createdAt: worktree.createdAt
    )
    repository = Repository(
      id: repository.id,
      rootURL: repository.rootURL,
      name: repository.name,
      worktrees: worktrees
    )
    state.repositories[index] = repository
    return
  }
}

private func updateWorktreeLineChanges(
  worktreeID: Worktree.ID,
  added: Int,
  removed: Int,
  state: inout RepositoriesFeature.State
) {
  var entry = state.worktreeInfoByID[worktreeID] ?? WorktreeInfoEntry()
  if added == 0 && removed == 0 {
    entry.addedLines = nil
    entry.removedLines = nil
  } else {
    entry.addedLines = added
    entry.removedLines = removed
  }
  if entry.isEmpty {
    state.worktreeInfoByID.removeValue(forKey: worktreeID)
  } else {
    state.worktreeInfoByID[worktreeID] = entry
  }
}

private func updateWorktreePullRequest(
  worktreeID: Worktree.ID,
  pullRequest: GithubPullRequest?,
  state: inout RepositoriesFeature.State
) {
  var entry = state.worktreeInfoByID[worktreeID] ?? WorktreeInfoEntry()
  entry.pullRequest = pullRequest
  if entry.isEmpty {
    state.worktreeInfoByID.removeValue(forKey: worktreeID)
  } else {
    state.worktreeInfoByID[worktreeID] = entry
  }
}

private func queuePullRequestRefresh(
  repositoryID: Repository.ID,
  repositoryRootURL: URL,
  worktreeIDs: [Worktree.ID],
  refreshesByRepositoryID: inout [Repository.ID: RepositoriesFeature.PendingPullRequestRefresh]
) {
  if var pending = refreshesByRepositoryID[repositoryID] {
    var seenWorktreeIDs = Set(pending.worktreeIDs)
    for worktreeID in worktreeIDs where seenWorktreeIDs.insert(worktreeID).inserted {
      pending.worktreeIDs.append(worktreeID)
    }
    refreshesByRepositoryID[repositoryID] = pending
  } else {
    refreshesByRepositoryID[repositoryID] = RepositoriesFeature.PendingPullRequestRefresh(
      repositoryRootURL: repositoryRootURL,
      worktreeIDs: worktreeIDs
    )
  }
}

private func reorderedUnpinnedWorktreeIDs(
  for worktreeID: Worktree.ID,
  in repository: Repository,
  state: RepositoriesFeature.State
) -> [Worktree.ID] {
  var ordered = state.orderedUnpinnedWorktreeIDs(in: repository)
  guard let index = ordered.firstIndex(of: worktreeID) else {
    return ordered
  }
  ordered.remove(at: index)
  ordered.insert(worktreeID, at: 0)
  return ordered
}

private func restoreSelection(
  _ id: Worktree.ID?,
  pendingID: Worktree.ID,
  state: inout RepositoriesFeature.State
) {
  guard state.selection == .worktree(pendingID) else { return }
  setSingleWorktreeSelection(
    isSelectionValid(id, state: state) ? id : nil,
    state: &state
  )
}

private func isSelectionValid(
  _ id: Worktree.ID?,
  state: RepositoriesFeature.State
) -> Bool {
  state.selectedRow(for: id) != nil
}

private func setSingleWorktreeSelection(
  _ worktreeID: Worktree.ID?,
  state: inout RepositoriesFeature.State
) {
  state.selection = worktreeID.map(SidebarSelection.worktree)
  if let worktreeID {
    state.sidebarSelectedWorktreeIDs = [worktreeID]
  } else {
    state.sidebarSelectedWorktreeIDs = []
  }
}

private func reduceSelectionChanged(
  into state: inout RepositoriesFeature.State,
  selections: Set<SidebarSelection>,
  focusTerminal: Bool
) -> Effect<RepositoriesFeature.Action> {
  let previousSelection = state.selectedWorktreeID
  let previousSelectedWorktree = state.worktree(for: previousSelection)

  guard !selections.contains(.archivedWorktrees) else {
    state.selection = .archivedWorktrees
    state.sidebarSelectedWorktreeIDs = []
    return .send(.delegate(.selectedWorktreeChanged(nil)))
  }

  let orderedRows = state.orderedSidebarItems()
  let orderedWorktreeIDs = orderedRows.map(\.id)
  let allWorktreeIDs = Set(orderedWorktreeIDs)
  let requestedWorktreeIDs = Set(selections.compactMap(\.worktreeID))
  let nextSidebarSelectedWorktreeIDs = requestedWorktreeIDs.intersection(allWorktreeIDs)
  let droppedIDs = requestedWorktreeIDs.subtracting(nextSidebarSelectedWorktreeIDs)
  if !droppedIDs.isEmpty {
    repositoriesLogger.debug("Selection dropped unknown worktree IDs: \(droppedIDs).")
  }

  guard !nextSidebarSelectedWorktreeIDs.isEmpty else {
    setSingleWorktreeSelection(nil, state: &state)
    return .send(.delegate(.selectedWorktreeChanged(nil)))
  }

  let nextSelectedWorktreeID =
    if let selectedWorktreeID = state.selectedWorktreeID,
      nextSidebarSelectedWorktreeIDs.contains(selectedWorktreeID)
    {
      selectedWorktreeID
    } else {
      orderedWorktreeIDs.first(where: nextSidebarSelectedWorktreeIDs.contains)
        ?? nextSidebarSelectedWorktreeIDs.first
    }

  state.selection = nextSelectedWorktreeID.map(SidebarSelection.worktree)
  state.sidebarSelectedWorktreeIDs = nextSidebarSelectedWorktreeIDs
  if focusTerminal,
    let nextSelectedWorktreeID,
    previousSelection != nextSelectedWorktreeID
  {
    state.pendingTerminalFocusWorktreeIDs.insert(nextSelectedWorktreeID)
  }

  let selectedWorktree = state.worktree(for: nextSelectedWorktreeID)
  let selectionChanged = selectionDidChange(
    previousSelectionID: previousSelection,
    previousSelectedWorktree: previousSelectedWorktree,
    selectedWorktreeID: nextSelectedWorktreeID,
    selectedWorktree: selectedWorktree
  )
  return selectionChanged ? .send(.delegate(.selectedWorktreeChanged(selectedWorktree))) : .none
}

private func selectionDidChange(
  previousSelectionID: Worktree.ID?,
  previousSelectedWorktree: Worktree?,
  selectedWorktreeID: Worktree.ID?,
  selectedWorktree: Worktree?
) -> Bool {
  previousSelectionID != selectedWorktreeID
    || previousSelectedWorktree?.workingDirectory != selectedWorktree?.workingDirectory
    || previousSelectedWorktree?.repositoryRootURL != selectedWorktree?.repositoryRootURL
}

private func repositoryForWorktreeCreation(
  _ state: RepositoriesFeature.State
) -> Repository? {
  // Only git repositories can host new worktrees — folders are
  // filtered out so the "New Worktree" hotkey / palette entry
  // resolves to a sibling git repo (or nothing) when the current
  // selection lives in a folder.
  if let selectedWorktreeID = state.selectedWorktreeID {
    if let pending = state.pendingWorktree(for: selectedWorktreeID),
      let pendingRepo = state.repositories[id: pending.repositoryID],
      pendingRepo.isGitRepository
    {
      return pendingRepo
    }
    for repository in state.repositories
    where repository.isGitRepository && repository.worktrees[id: selectedWorktreeID] != nil {
      return repository
    }
  }
  let gitRepositories = state.repositories.filter(\.isGitRepository)
  if gitRepositories.count == 1 {
    return gitRepositories.first
  }
  return nil
}

/// Reconcile the nested `SidebarState` against the currently-known
/// repositories + worktrees in one atomic `$sidebar.withLock`.
/// Replaces the legacy four-way prune (pinned / collapsed / repo
/// order / worktree order) that each needed a separate save effect.
///
/// Keeps section entries for `roots` that have not yet materialised
/// as loaded `Repository` instances — the loaded-roots-but-not-
/// resolved window happens every startup, and nuking collapse/order
/// state there would silently reset the user's curation. Inside a
/// resolved section, drops items whose worktree no longer exists
/// and isn't archived, and items that point at the repo's "main"
/// worktree (main rows don't live in the sidebar list). Archived
/// items (`archivedAt != nil`) stay put regardless of live-roster
/// membership — they ARE the archive record, not a duplicate of it.
///
/// Also seeds `.unpinned` entries for every live non-main worktree
/// that isn't already curated in some bucket, so the mutation path
/// can assume "every live worktree has a bucketed entry" and the
/// pin/archive actions don't need fallback materialisation. This
/// seed is the load-bearing invariant the rest of the reducer relies
/// on — renaming away from "prune" makes that contract explicit.
///
/// Finally, sections whose repository has disappeared from the live
/// roots but still carry user-curated `.archived` or `.pinned`
/// buckets are carried forward as stripped tombstones (archived +
/// pinned only, collapsed reset, `.unpinned` dropped) so a repo
/// temporarily missing from a partial reload doesn't destroy the
/// archive record or pin list.
///
/// The rebuilt `sections` is compared to the current value before
/// the `withLock`; identical rebuilds short-circuit so branch-flutter
/// reloads don't re-encode + re-save `sidebar.json` on every tick.
///
/// `pruneLivenessAgainstRoster` gates the destructive drop of
/// `.pinned` / `.unpinned` items whose worktree isn't in the live
/// roster. When `false`, curated items in those buckets are copied
/// forward verbatim — only the main-row filter and the seed pass
/// apply. The call site passes `state.isInitialLoadComplete` so the
/// first `.repositoriesLoaded` (which can race with
/// `Repository.worktrees` hydration and transiently miss
/// migrator-written IDs) can't silently drop curation. Subsequent
/// loads prune as before.
private func reconcileSidebarState(
  roots: [URL],
  state: inout RepositoriesFeature.State,
  pruneLivenessAgainstRoster: Bool
) {
  // Empty-everything reload → bail. A settings-file read failure or
  // a pre-rehydration window can land here with zero roots + zero
  // repos; overwriting `sidebar.json` from that state would
  // obliterate the user's curation.
  if roots.isEmpty, state.repositories.isEmpty {
    return
  }

  let rootIDs: Set<Repository.ID> = Set(roots.map { $0.standardizedFileURL.path(percentEncoded: false) })
  let localIDs = Set(state.repositories.map(\.id))
  let availableRepoIDs = localIDs.union(rootIDs)
  let repositoriesByID = Dictionary(uniqueKeysWithValues: state.repositories.map { ($0.id, $0) })

  var rebuilt: OrderedDictionary<Repository.ID, SidebarState.Section> = [:]
  for (repoID, section) in state.sidebar.sections where availableRepoIDs.contains(repoID) {
    guard let repository = repositoriesByID[repoID] else {
      // Local roots still loading. Preserve the section verbatim
      // — we'll re-prune its items once the roster is known.
      rebuilt[repoID] = section
      continue
    }
    let mainID = repository.worktrees.first(where: { state.isMainWorktree($0) })?.id
    let worktreeIDs = Set(repository.worktrees.map(\.id))
    var copy = section
    // Walk every bucket. `.archived` is the archive record —
    // preserve its items regardless of live-roster membership.
    // `.pinned` and `.unpinned` only hold curated pointers into
    // the live roster, so normally drop entries whose worktree
    // no longer exists or that point at the main row. When
    // `pruneLivenessAgainstRoster` is `false` (first load after
    // migration), keep every curated item that isn't the main
    // row so migrated IDs survive a transient roster view; the
    // next `.repositoriesLoaded` will prune for real.
    var seenInCuratedBuckets: Set<Worktree.ID> = []
    for (bucketID, bucket) in copy.buckets {
      if bucketID == .archived {
        continue
      }
      var prunedItems: OrderedDictionary<Worktree.ID, SidebarState.Item> = [:]
      for (worktreeID, item) in bucket.items {
        if worktreeID == mainID {
          continue
        }
        if pruneLivenessAgainstRoster, !worktreeIDs.contains(worktreeID) {
          continue
        }
        prunedItems[worktreeID] = item
        seenInCuratedBuckets.insert(worktreeID)
      }
      var prunedBucket = bucket
      prunedBucket.items = prunedItems
      copy.buckets[bucketID] = prunedBucket
    }
    // Capture worktree IDs already living in `.archived` so the
    // seed pass doesn't resurrect them into `.unpinned`.
    var archivedIDs: Set<Worktree.ID> = []
    if let archivedBucket = copy.buckets[.archived] {
      archivedIDs = Set(archivedBucket.items.keys)
    }
    // Seed every live non-main worktree that isn't already curated
    // in some bucket into `.unpinned` at the tail. This makes the
    // sidebar state total, so mutation actions can assume every
    // live worktree has a bucket and skip fallback materialisation.
    for worktree in repository.worktrees {
      if worktree.id == mainID {
        continue
      }
      if seenInCuratedBuckets.contains(worktree.id) || archivedIDs.contains(worktree.id) {
        continue
      }
      var unpinned = copy.buckets[.unpinned] ?? .init()
      unpinned.items[worktree.id] = .init()
      copy.buckets[.unpinned] = unpinned
    }
    rebuilt[repoID] = copy
  }

  // Seed a default (empty) section for every live repository that
  // doesn't yet have a `sidebar.sections` entry. Without this, a
  // brand-new repo (git or folder) only surfaces through the
  // `orderedRepositoryRoots()` fallback path and SwiftUI's List
  // diffing can miss the insertion until the next reconcile pass.
  //
  // Folders intentionally keep an empty section — they have no
  // pin / unpin / archive buckets — so the entry stays trivial. A
  // user re-`git init`-ing a folder would have the section ready
  // to accept curated bucket entries without a follow-up reconcile.
  for repository in state.repositories where rebuilt[repository.id] == nil {
    rebuilt[repository.id] = SidebarState.Section()
  }

  preserveOrphanSections(
    from: state.sidebar.sections,
    availableRepoIDs: availableRepoIDs,
    into: &rebuilt
  )

  // Equality-gate the write. Branch-change and filesystem-flutter
  // reloads fire `.repositoriesLoaded` every few seconds even when
  // the roster is unchanged; entering `$sidebar.withLock` with an
  // identical rebuild would still trigger the SharedKey save path
  // and re-encode + re-atomic-write `sidebar.json` needlessly.
  guard rebuilt != state.sidebar.sections else {
    return
  }
  state.$sidebar.withLock { sidebar in
    sidebar.sections = rebuilt
  }
}

/// Preserve user-curated `.archived` and `.pinned` buckets and
/// `title` / `color` customization for repositories no longer
/// present in `availableRepoIDs`. A repo can vanish from the live
/// roster for legitimate reasons (removed from Settings →
/// Repositories) or transient ones (a partial reload where
/// resolution failed). In either case the archive record, pin list,
/// and customization fields are user-curated data we must not drop
/// silently. This emits a stripped tombstone section: only non-empty
/// `.archived` and `.pinned` are carried verbatim, `.unpinned` is
/// dropped (it's regenerated by the seed pass on the next full
/// load), `collapsed` resets to its default, and `title` / `color`
/// are carried so a transient reload doesn't strip a user's repo
/// rename or tint. Tombstones are appended after the active repos so
/// the natural ordering stays "live repos first, orphan-but-curated
/// at the tail".
private func preserveOrphanSections(
  from oldSections: OrderedDictionary<Repository.ID, SidebarState.Section>,
  availableRepoIDs: Set<Repository.ID>,
  into rebuilt: inout OrderedDictionary<Repository.ID, SidebarState.Section>
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

private func pruneArchivedWorktreeIDs(
  availableWorktreeIDs: Set<Worktree.ID>,
  state: inout RepositoriesFeature.State
) -> Bool {
  var didChange = false
  state.$sidebar.withLock { sidebar in
    for (repoID, section) in sidebar.sections {
      guard let archived = section.buckets[.archived] else { continue }
      for worktreeID in archived.items.keys
      where !availableWorktreeIDs.contains(worktreeID) {
        sidebar.sections[repoID]?.buckets[.archived]?.items.removeValue(forKey: worktreeID)
        didChange = true
      }
    }
  }
  return didChange
}

private func firstAvailableWorktreeID(
  from repositories: [Repository],
  state: RepositoriesFeature.State
) -> Worktree.ID? {
  for repository in repositories {
    if let first = state.orderedWorktrees(in: repository).first {
      return first.id
    }
  }
  return nil
}

private func firstAvailableWorktreeID(
  in repositoryID: Repository.ID,
  state: RepositoriesFeature.State
) -> Worktree.ID? {
  guard let repository = state.repositories[id: repositoryID] else {
    return nil
  }
  return state.orderedWorktrees(in: repository).first?.id
}

private func nextWorktreeID(
  afterRemoving worktree: Worktree,
  in repository: Repository,
  state: RepositoriesFeature.State
) -> Worktree.ID? {
  let orderedIDs = state.orderedWorktrees(in: repository).map(\.id)
  guard let index = orderedIDs.firstIndex(of: worktree.id) else { return nil }
  let nextIndex = index + 1
  if nextIndex < orderedIDs.count {
    return orderedIDs[nextIndex]
  }
  if index > 0 {
    return orderedIDs[index - 1]
  }
  return nil
}

extension String {
  /// Returns the remote name if this ref starts with `<remote>/`, matched against known remotes.
  /// Matches the longest remote name first to handle ambiguous prefixes.
  fileprivate nonisolated func matchingRemote(from remotes: [String]) -> String? {
    remotes
      .sorted { $0.count > $1.count }
      .first { hasPrefix("\($0)/") }
  }
}
