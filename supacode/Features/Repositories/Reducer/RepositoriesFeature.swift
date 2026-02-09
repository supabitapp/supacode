import AppKit
import ComposableArchitecture
import Foundation
import IdentifiedCollections
import PostHog
import SwiftUI

private enum CancelID {
  static let load = "repositories.load"
  static let toastAutoDismiss = "repositories.toastAutoDismiss"
  static func delayedPRRefresh(_ worktreeID: Worktree.ID) -> String {
    "repositories.delayedPRRefresh.\(worktreeID)"
  }
}

@Reducer
struct RepositoriesFeature {
  @ObservableState
  struct State: Equatable {
    var repositories: IdentifiedArrayOf<Repository> = []
    var repositoryRoots: [URL] = []
    var repositoryOrderIDs: [Repository.ID] = []
    var loadFailuresByID: [Repository.ID: String] = [:]
    var selection: SidebarSelection?
    var worktreeInfoByID: [Worktree.ID: WorktreeInfoEntry] = [:]
    var worktreeOrderByRepository: [Repository.ID: [Worktree.ID]] = [:]
    var isOpenPanelPresented = false
    var isInitialLoadComplete = false
    var pendingWorktrees: [PendingWorktree] = []
    var pendingSetupScriptWorktreeIDs: Set<Worktree.ID> = []
    var pendingTerminalFocusWorktreeIDs: Set<Worktree.ID> = []
    var deletingWorktreeIDs: Set<Worktree.ID> = []
    var removingRepositoryIDs: Set<Repository.ID> = []
    var pinnedWorktreeIDs: [Worktree.ID] = []
    var archivedWorktreeIDs: [Worktree.ID] = []
    var automaticallyArchiveMergedWorktrees = false
    var lastFocusedWorktreeID: Worktree.ID?
    var shouldRestoreLastFocusedWorktree = false
    var shouldSelectFirstAfterReload = false
    var isRefreshingWorktrees = false
    var statusToast: StatusToast?
    @Presents var alert: AlertState<Alert>?
  }

  enum Action {
    case task
    case setOpenPanelPresented(Bool)
    case loadPersistedRepositories
    case pinnedWorktreeIDsLoaded([Worktree.ID])
    case archivedWorktreeIDsLoaded([Worktree.ID])
    case repositoryOrderIDsLoaded([Repository.ID])
    case worktreeOrderByRepositoryLoaded([Repository.ID: [Worktree.ID]])
    case lastFocusedWorktreeIDLoaded(Worktree.ID?)
    case refreshWorktrees
    case reloadRepositories(animated: Bool)
    case repositoriesLoaded([Repository], failures: [LoadFailure], roots: [URL], animated: Bool)
    case selectArchivedWorktrees
    case openRepositories([URL])
    case openRepositoriesFinished(
      [Repository],
      failures: [LoadFailure],
      invalidRoots: [String],
      roots: [URL]
    )
    case selectWorktree(Worktree.ID?)
    case requestRenameBranch(Worktree.ID, String)
    case createRandomWorktree
    case createRandomWorktreeInRepository(Repository.ID)
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
      name: String?
    )
    case consumeSetupScript(Worktree.ID)
    case consumeTerminalFocus(Worktree.ID)
    case requestArchiveWorktree(Worktree.ID, Repository.ID)
    case archiveWorktreeConfirmed(Worktree.ID, Repository.ID)
    case unarchiveWorktree(Worktree.ID)
    case requestDeleteWorktree(Worktree.ID, Repository.ID)
    case requestDeleteWorktrees([DeleteWorktreeTarget])
    case deleteWorktreeConfirmed(Worktree.ID, Repository.ID)
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
    case requestRemoveRepository(Repository.ID)
    case removeFailedRepository(Repository.ID)
    case repositoryRemoved(Repository.ID, selectionWasRemoved: Bool)
    case pinWorktree(Worktree.ID)
    case unpinWorktree(Worktree.ID)
    case presentAlert(title: String, message: String)
    case worktreeInfoEvent(WorktreeInfoWatcherClient.Event)
    case worktreeNotificationReceived(Worktree.ID)
    case worktreeBranchNameLoaded(worktreeID: Worktree.ID, name: String)
    case worktreeLineChangesLoaded(worktreeID: Worktree.ID, added: Int, removed: Int)
    case worktreePullRequestLoaded(worktreeID: Worktree.ID, pullRequest: GithubPullRequest?)
    case setGithubIntegrationEnabled(Bool)
    case setAutomaticallyArchiveMergedWorktrees(Bool)
    case pullRequestAction(Worktree.ID, PullRequestAction)
    case showToast(StatusToast)
    case dismissToast
    case delayedPullRequestRefresh(Worktree.ID)
    case openRepositorySettings(Repository.ID)
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

  private struct ApplyRepositoriesResult {
    let didPrunePinned: Bool
    let didPruneRepositoryOrder: Bool
    let didPruneWorktreeOrder: Bool
    let didPruneArchivedWorktreeIDs: Bool
  }

  enum StatusToast: Equatable {
    case inProgress(String)
    case success(String)
  }

  enum Alert: Equatable {
    case confirmArchiveWorktree(Worktree.ID, Repository.ID)
    case confirmDeleteWorktree(Worktree.ID, Repository.ID)
    case confirmDeleteWorktrees([DeleteWorktreeTarget])
    case confirmRemoveRepository(Repository.ID)
  }

  enum PullRequestAction: Equatable {
    case openOnGithub
    case markReadyForReview
    case merge
    case copyCiFailureLogs
    case rerunFailedJobs
    case openFailingCheckDetails
  }

  @CasePathable
  enum Delegate: Equatable {
    case selectedWorktreeChanged(Worktree?)
    case repositoriesChanged(IdentifiedArrayOf<Repository>)
    case openRepositorySettings(Repository.ID)
    case worktreeCreated(Worktree)
  }

  @Dependency(\.analyticsClient) private var analyticsClient
  @Dependency(\.gitClient) private var gitClient
  @Dependency(\.githubCLI) private var githubCLI
  @Dependency(\.githubIntegration) private var githubIntegration
  @Dependency(\.repositoryPersistence) private var repositoryPersistence
  @Dependency(\.uuid) private var uuid

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .task:
        return .run { send in
          let pinned = await repositoryPersistence.loadPinnedWorktreeIDs()
          let archived = await repositoryPersistence.loadArchivedWorktreeIDs()
          let lastFocused = await repositoryPersistence.loadLastFocusedWorktreeID()
          let repositoryOrderIDs = await repositoryPersistence.loadRepositoryOrderIDs()
          let worktreeOrderByRepository =
            await repositoryPersistence.loadWorktreeOrderByRepository()
          await send(.pinnedWorktreeIDsLoaded(pinned))
          await send(.archivedWorktreeIDsLoaded(archived))
          await send(.repositoryOrderIDsLoaded(repositoryOrderIDs))
          await send(.worktreeOrderByRepositoryLoaded(worktreeOrderByRepository))
          await send(.lastFocusedWorktreeIDLoaded(lastFocused))
          await send(.loadPersistedRepositories)
        }

      case .pinnedWorktreeIDsLoaded(let pinnedWorktreeIDs):
        state.pinnedWorktreeIDs = pinnedWorktreeIDs
        return .none

      case .archivedWorktreeIDsLoaded(let archivedWorktreeIDs):
        state.archivedWorktreeIDs = archivedWorktreeIDs
        return .none

      case .repositoryOrderIDsLoaded(let repositoryOrderIDs):
        state.repositoryOrderIDs = repositoryOrderIDs
        return .none

      case .worktreeOrderByRepositoryLoaded(let worktreeOrderByRepository):
        state.worktreeOrderByRepository = worktreeOrderByRepository
        return .none

      case .lastFocusedWorktreeIDLoaded(let lastFocusedWorktreeID):
        state.lastFocusedWorktreeID = lastFocusedWorktreeID
        state.shouldRestoreLastFocusedWorktree = true
        return .none

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
        state.alert = nil
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
        let applyResult = applyRepositories(
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
        if applyResult.didPrunePinned {
          let pinnedWorktreeIDs = state.pinnedWorktreeIDs
          allEffects.append(
            .run { _ in
              await repositoryPersistence.savePinnedWorktreeIDs(pinnedWorktreeIDs)
            })
        }
        if applyResult.didPruneRepositoryOrder {
          let repositoryOrderIDs = state.repositoryOrderIDs
          allEffects.append(
            .run { _ in
              await repositoryPersistence.saveRepositoryOrderIDs(repositoryOrderIDs)
            })
        }
        if applyResult.didPruneWorktreeOrder {
          let worktreeOrderByRepository = state.worktreeOrderByRepository
          allEffects.append(
            .run { _ in
              await repositoryPersistence.saveWorktreeOrderByRepository(worktreeOrderByRepository)
            })
        }
        if applyResult.didPruneArchivedWorktreeIDs {
          let archivedWorktreeIDs = state.archivedWorktreeIDs
          allEffects.append(
            .run { _ in
              await repositoryPersistence.saveArchivedWorktreeIDs(archivedWorktreeIDs)
            }
          )
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
              invalidRoots.append(url.path(percentEncoded: false))
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
        let applyResult = applyRepositories(
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
          let message = invalidRoots.map { "\($0) is not a Git repository." }.joined(separator: "\n")
          state.alert = messageAlert(
            title: "Some folders couldn't be opened",
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
        if applyResult.didPrunePinned {
          let pinnedWorktreeIDs = state.pinnedWorktreeIDs
          allEffects.append(
            .run { _ in
              await repositoryPersistence.savePinnedWorktreeIDs(pinnedWorktreeIDs)
            })
        }
        if applyResult.didPruneRepositoryOrder {
          let repositoryOrderIDs = state.repositoryOrderIDs
          allEffects.append(
            .run { _ in
              await repositoryPersistence.saveRepositoryOrderIDs(repositoryOrderIDs)
            })
        }
        if applyResult.didPruneWorktreeOrder {
          let worktreeOrderByRepository = state.worktreeOrderByRepository
          allEffects.append(
            .run { _ in
              await repositoryPersistence.saveWorktreeOrderByRepository(worktreeOrderByRepository)
            })
        }
        if applyResult.didPruneArchivedWorktreeIDs {
          let archivedWorktreeIDs = state.archivedWorktreeIDs
          allEffects.append(
            .run { _ in
              await repositoryPersistence.saveArchivedWorktreeIDs(archivedWorktreeIDs)
            }
          )
        }
        return .merge(allEffects)

      case .selectArchivedWorktrees:
        state.selection = .archivedWorktrees
        return .send(.delegate(.selectedWorktreeChanged(nil)))

      case .selectWorktree(let worktreeID):
        state.selection = worktreeID.map(SidebarSelection.worktree)
        let selectedWorktree = state.worktree(for: worktreeID)
        return .send(.delegate(.selectedWorktreeChanged(selectedWorktree)))

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
        if state.removingRepositoryIDs.contains(repository.id) {
          state.alert = messageAlert(
            title: "Unable to create worktree",
            message: "This repository is being removed."
          )
          return .none
        }
        let previousSelection = state.selectedWorktreeID
        let pendingID = "pending:\(uuid().uuidString)"
        @Shared(.repositorySettings(repository.rootURL)) var repositorySettings
        let selectedBaseRef = repositorySettings.worktreeBaseRef
        let copyIgnoredOnWorktreeCreate = repositorySettings.copyIgnoredOnWorktreeCreate
        let copyUntrackedOnWorktreeCreate = repositorySettings.copyUntrackedOnWorktreeCreate
        state.pendingWorktrees.append(
          PendingWorktree(
            id: pendingID,
            repositoryID: repository.id,
            name: "Creating worktree...",
            detail: ""
          )
        )
        state.selection = .worktree(pendingID)
        let existingNames = Set(repository.worktrees.map { $0.name.lowercased() })
        return .run { send in
          var newWorktreeName: String?
          do {
            let branchNames = try await gitClient.localBranchNames(repository.rootURL)
            let existing = existingNames.union(branchNames)
            let name = await MainActor.run {
              WorktreeNameGenerator.nextName(excluding: existing)
            }
            guard let name else {
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
                  name: nil
                )
              )
              return
            }
            newWorktreeName = name
            let isBareRepository = (try? await gitClient.isBareRepository(repository.rootURL)) ?? false
            let copyIgnored = isBareRepository ? false : copyIgnoredOnWorktreeCreate
            let copyUntracked = isBareRepository ? false : copyUntrackedOnWorktreeCreate
            let resolvedBaseRef: String
            if (selectedBaseRef ?? "").isEmpty {
              resolvedBaseRef = await gitClient.automaticWorktreeBaseRef(repository.rootURL) ?? ""
            } else {
              resolvedBaseRef = selectedBaseRef ?? ""
            }
            let newWorktree = try await gitClient.createWorktree(
              name,
              repository.rootURL,
              copyIgnored,
              copyUntracked,
              resolvedBaseRef
            )
            await send(
              .createRandomWorktreeSucceeded(
                newWorktree,
                repositoryID: repository.id,
                pendingID: pendingID
              )
            )
          } catch {
            await send(
              .createRandomWorktreeFailed(
                title: "Unable to create worktree",
                message: error.localizedDescription,
                pendingID: pendingID,
                previousSelection: previousSelection,
                repositoryID: repository.id,
                name: newWorktreeName
              )
            )
          }
        }

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
          state.selection = .worktree(worktree.id)
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
        let name
      ):
        let previousSelectedWorktree = state.worktree(for: previousSelection)
        removePendingWorktree(pendingID, state: &state)
        restoreSelection(previousSelection, pendingID: pendingID, state: &state)
        let cleanup = cleanupFailedWorktree(
          repositoryID: repositoryID,
          name: name,
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
        if cleanup.didUpdatePinned {
          let pinnedWorktreeIDs = state.pinnedWorktreeIDs
          effects.append(
            .run { _ in
              await repositoryPersistence.savePinnedWorktreeIDs(pinnedWorktreeIDs)
            }
          )
        }
        if cleanup.didUpdateOrder {
          let worktreeOrderByRepository = state.worktreeOrderByRepository
          effects.append(
            .run { _ in
              await repositoryPersistence.saveWorktreeOrderByRepository(worktreeOrderByRepository)
            }
          )
        }
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
        if state.removingRepositoryIDs.contains(repositoryID) {
          return .none
        }
        guard let repository = state.repositories[id: repositoryID],
          let worktree = repository.worktrees[id: worktreeID]
        else {
          return .none
        }
        if state.isMainWorktree(worktree) {
          return .none
        }
        if state.deletingWorktreeIDs.contains(worktree.id) {
          return .none
        }
        if state.isWorktreeArchived(worktree.id) {
          return .none
        }
        if state.isWorktreeMerged(worktree) {
          return .send(.archiveWorktreeConfirmed(worktree.id, repository.id))
        }
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
          TextState("Archive \(worktree.name)?")
        }
        return .none

      case .alert(.presented(.confirmArchiveWorktree(let worktreeID, let repositoryID))):
        return .send(.archiveWorktreeConfirmed(worktreeID, repositoryID))

      case .archiveWorktreeConfirmed(let worktreeID, let repositoryID):
        guard let repository = state.repositories[id: repositoryID],
          let worktree = repository.worktrees[id: worktreeID]
        else {
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
        var didUpdateWorktreeOrder = false
        let wasPinned = state.pinnedWorktreeIDs.contains(worktreeID)
        withAnimation {
          state.alert = nil
          state.pinnedWorktreeIDs.removeAll { $0 == worktreeID }
          if var order = state.worktreeOrderByRepository[repositoryID] {
            order.removeAll { $0 == worktreeID }
            if order.isEmpty {
              state.worktreeOrderByRepository.removeValue(forKey: repositoryID)
            } else {
              state.worktreeOrderByRepository[repositoryID] = order
            }
            didUpdateWorktreeOrder = true
          }
          state.archivedWorktreeIDs.append(worktreeID)
          if selectionWasRemoved {
            let nextWorktreeID = nextSelection ?? firstAvailableWorktreeID(in: repositoryID, state: state)
            state.selection = nextWorktreeID.map(SidebarSelection.worktree)
          }
        }
        let archivedWorktreeIDs = state.archivedWorktreeIDs
        let repositories = state.repositories
        let selectedWorktree = state.worktree(for: state.selectedWorktreeID)
        let selectionChanged = selectionDidChange(
          previousSelectionID: previousSelection,
          previousSelectedWorktree: previousSelectedWorktree,
          selectedWorktreeID: state.selectedWorktreeID,
          selectedWorktree: selectedWorktree
        )
        var effects: [Effect<Action>] = [
          .send(.delegate(.repositoriesChanged(repositories))),
          .run { _ in
            await repositoryPersistence.saveArchivedWorktreeIDs(archivedWorktreeIDs)
          },
        ]
        if wasPinned {
          let pinnedWorktreeIDs = state.pinnedWorktreeIDs
          effects.append(
            .run { _ in
              await repositoryPersistence.savePinnedWorktreeIDs(pinnedWorktreeIDs)
            }
          )
        }
        if didUpdateWorktreeOrder {
          let worktreeOrderByRepository = state.worktreeOrderByRepository
          effects.append(
            .run { _ in
              await repositoryPersistence.saveWorktreeOrderByRepository(worktreeOrderByRepository)
            }
          )
        }
        if selectionChanged {
          effects.append(.send(.delegate(.selectedWorktreeChanged(selectedWorktree))))
        }
        return .merge(effects)

      case .unarchiveWorktree(let worktreeID):
        if !state.isWorktreeArchived(worktreeID) {
          return .none
        }
        withAnimation {
          state.archivedWorktreeIDs.removeAll { $0 == worktreeID }
        }
        let archivedWorktreeIDs = state.archivedWorktreeIDs
        let repositories = state.repositories
        return .merge(
          .send(.delegate(.repositoriesChanged(repositories))),
          .run { _ in
            await repositoryPersistence.saveArchivedWorktreeIDs(archivedWorktreeIDs)
          }
        )

      case .requestDeleteWorktree(let worktreeID, let repositoryID):
        if state.removingRepositoryIDs.contains(repositoryID) {
          return .none
        }
        guard let repository = state.repositories[id: repositoryID],
          let worktree = repository.worktrees[id: worktreeID]
        else {
          return .none
        }
        if state.isMainWorktree(worktree) {
          state.alert = messageAlert(
            title: "Delete not allowed",
            message: "Deleting the main worktree is not allowed."
          )
          return .none
        }
        if state.deletingWorktreeIDs.contains(worktree.id) {
          return .none
        }
        @Shared(.settingsFile) var settingsFile
        let deleteBranchOnDeleteWorktree = settingsFile.global.deleteBranchOnDeleteWorktree
        let removalMessage =
          deleteBranchOnDeleteWorktree
          ? "This deletes the worktree directory and its local branch."
          : "This deletes the worktree directory and keeps the local branch."
        state.alert = AlertState {
          TextState("🚨 Delete worktree?")
        } actions: {
          ButtonState(role: .destructive, action: .confirmDeleteWorktree(worktree.id, repository.id)) {
            TextState("Delete (⌘↩)")
          }
          ButtonState(role: .cancel) {
            TextState("Cancel")
          }
        } message: {
          TextState("Delete \(worktree.name)? " + removalMessage)
        }
        return .none

      case .requestDeleteWorktrees(let targets):
        var validTargets: [DeleteWorktreeTarget] = []
        var seenWorktreeIDs: Set<Worktree.ID> = []
        for target in targets {
          guard seenWorktreeIDs.insert(target.worktreeID).inserted else { continue }
          if state.removingRepositoryIDs.contains(target.repositoryID) {
            continue
          }
          guard let repository = state.repositories[id: target.repositoryID],
            let worktree = repository.worktrees[id: target.worktreeID]
          else {
            continue
          }
          if state.isMainWorktree(worktree) || state.deletingWorktreeIDs.contains(worktree.id) {
            continue
          }
          validTargets.append(target)
        }
        guard !validTargets.isEmpty else {
          return .none
        }
        @Shared(.settingsFile) var settingsFile
        let deleteBranchOnDeleteWorktree = settingsFile.global.deleteBranchOnDeleteWorktree
        let removalMessage =
          deleteBranchOnDeleteWorktree
          ? "This deletes the worktree directories and their local branches."
          : "This deletes the worktree directories and keeps their local branches."
        let count = validTargets.count
        state.alert = AlertState {
          TextState("🚨 Delete \(count) worktrees?")
        } actions: {
          ButtonState(role: .destructive, action: .confirmDeleteWorktrees(validTargets)) {
            TextState("Delete \(count) (⌘↩)")
          }
          ButtonState(role: .cancel) {
            TextState("Cancel")
          }
        } message: {
          TextState("Delete \(count) worktrees? " + removalMessage)
        }
        return .none

      case .alert(.presented(.confirmDeleteWorktree(let worktreeID, let repositoryID))):
        return .send(.deleteWorktreeConfirmed(worktreeID, repositoryID))

      case .alert(.presented(.confirmDeleteWorktrees(let targets))):
        return .merge(
          targets.map { target in
            .send(.deleteWorktreeConfirmed(target.worktreeID, target.repositoryID))
          }
        )

      case .deleteWorktreeConfirmed(let worktreeID, let repositoryID):
        guard let repository = state.repositories[id: repositoryID],
          let worktree = repository.worktrees[id: worktreeID]
        else {
          return .none
        }
        if state.deletingWorktreeIDs.contains(worktree.id) {
          return .none
        }
        state.alert = nil
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
        let wasPinned = state.pinnedWorktreeIDs.contains(worktreeID)
        var didUpdateWorktreeOrder = false
        let wasArchived = state.isWorktreeArchived(worktreeID)
        withAnimation(.easeOut(duration: 0.2)) {
          state.deletingWorktreeIDs.remove(worktreeID)
          state.pendingWorktrees.removeAll { $0.id == worktreeID }
          state.pendingSetupScriptWorktreeIDs.remove(worktreeID)
          state.pendingTerminalFocusWorktreeIDs.remove(worktreeID)
          state.worktreeInfoByID.removeValue(forKey: worktreeID)
          state.pinnedWorktreeIDs.removeAll { $0 == worktreeID }
          state.archivedWorktreeIDs.removeAll { $0 == worktreeID }
          if var order = state.worktreeOrderByRepository[repositoryID] {
            order.removeAll { $0 == worktreeID }
            if order.isEmpty {
              state.worktreeOrderByRepository.removeValue(forKey: repositoryID)
            } else {
              state.worktreeOrderByRepository[repositoryID] = order
            }
            didUpdateWorktreeOrder = true
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
        var followupEffects: [Effect<Action>] = [
          roots.isEmpty ? .none : .send(.reloadRepositories(animated: true))
        ]
        if wasPinned {
          let pinnedWorktreeIDs = state.pinnedWorktreeIDs
          followupEffects.append(
            .run { _ in
              await repositoryPersistence.savePinnedWorktreeIDs(pinnedWorktreeIDs)
            }
          )
        }
        if wasArchived {
          let archivedWorktreeIDs = state.archivedWorktreeIDs
          followupEffects.append(
            .run { _ in
              await repositoryPersistence.saveArchivedWorktreeIDs(archivedWorktreeIDs)
            }
          )
        }
        if didUpdateWorktreeOrder {
          let worktreeOrderByRepository = state.worktreeOrderByRepository
          followupEffects.append(
            .run { _ in
              await repositoryPersistence.saveWorktreeOrderByRepository(worktreeOrderByRepository)
            }
          )
        }
        return .concatenate(
          .merge(immediateEffects),
          .merge(followupEffects)
        )

      case .repositoriesMoved(let offsets, let destination):
        var ordered = state.orderedRepositoryIDs()
        ordered.move(fromOffsets: offsets, toOffset: destination)
        withAnimation(.snappy(duration: 0.2)) {
          state.repositoryOrderIDs = ordered
        }
        let repositoryOrderIDs = state.repositoryOrderIDs
        return .run { _ in
          await repositoryPersistence.saveRepositoryOrderIDs(repositoryOrderIDs)
        }

      case .pinnedWorktreesMoved(let repositoryID, let offsets, let destination):
        guard let repository = state.repositories[id: repositoryID] else { return .none }
        let currentPinned = state.orderedPinnedWorktreeIDs(in: repository)
        guard currentPinned.count > 1 else { return .none }
        var reordered = currentPinned
        reordered.move(fromOffsets: offsets, toOffset: destination)
        withAnimation(.snappy(duration: 0.2)) {
          state.pinnedWorktreeIDs = state.replacingPinnedWorktreeIDs(
            in: repository,
            with: reordered
          )
        }
        let pinnedWorktreeIDs = state.pinnedWorktreeIDs
        return .run { _ in
          await repositoryPersistence.savePinnedWorktreeIDs(pinnedWorktreeIDs)
        }

      case .unpinnedWorktreesMoved(let repositoryID, let offsets, let destination):
        guard let repository = state.repositories[id: repositoryID] else { return .none }
        let currentUnpinned = state.orderedUnpinnedWorktreeIDs(in: repository)
        guard currentUnpinned.count > 1 else { return .none }
        var reordered = currentUnpinned
        reordered.move(fromOffsets: offsets, toOffset: destination)
        withAnimation(.snappy(duration: 0.2)) {
          state.worktreeOrderByRepository[repositoryID] = reordered
        }
        let worktreeOrderByRepository = state.worktreeOrderByRepository
        return .run { _ in
          await repositoryPersistence.saveWorktreeOrderByRepository(worktreeOrderByRepository)
        }

      case .deleteWorktreeFailed(let message, let worktreeID):
        state.deletingWorktreeIDs.remove(worktreeID)
        state.alert = messageAlert(title: "Unable to delete worktree", message: message)
        return .none

      case .requestRemoveRepository(let repositoryID):
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

      case .alert(.presented(.confirmRemoveRepository(let repositoryID))):
        guard let repository = state.repositories[id: repositoryID] else {
          return .none
        }
        if state.removingRepositoryIDs.contains(repository.id) {
          return .none
        }
        state.alert = nil
        state.removingRepositoryIDs.insert(repository.id)
        let selectionWasRemoved =
          state.selectedWorktreeID.map { id in
            repository.worktrees.contains(where: { $0.id == id })
          } ?? false
        return .send(.repositoryRemoved(repository.id, selectionWasRemoved: selectionWasRemoved))

      case .repositoryRemoved(let repositoryID, let selectionWasRemoved):
        analyticsClient.capture("repository_removed", nil)
        state.removingRepositoryIDs.remove(repositoryID)
        if selectionWasRemoved {
          state.selection = nil
          state.shouldSelectFirstAfterReload = true
        }
        let selectedWorktree = state.worktree(for: state.selectedWorktreeID)
        return .merge(
          .send(.delegate(.selectedWorktreeChanged(selectedWorktree))),
          .run { send in
            let loadedPaths = await repositoryPersistence.loadRoots()
            var seen: Set<String> = []
            let rootPaths = loadedPaths.filter { seen.insert($0).inserted }
            let remaining = rootPaths.filter { $0 != repositoryID }
            await repositoryPersistence.saveRoots(remaining)
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
        )

      case .pinWorktree(let worktreeID):
        if let worktree = state.worktree(for: worktreeID), state.isMainWorktree(worktree) {
          let wasPinned = state.pinnedWorktreeIDs.contains(worktreeID)
          state.pinnedWorktreeIDs.removeAll { $0 == worktreeID }
          var didUpdateWorktreeOrder = false
          if let repositoryID = state.repositoryID(containing: worktreeID),
            var order = state.worktreeOrderByRepository[repositoryID]
          {
            order.removeAll { $0 == worktreeID }
            if order.isEmpty {
              state.worktreeOrderByRepository.removeValue(forKey: repositoryID)
            } else {
              state.worktreeOrderByRepository[repositoryID] = order
            }
            didUpdateWorktreeOrder = true
          }
          var effects: [Effect<Action>] = []
          if wasPinned {
            let pinnedWorktreeIDs = state.pinnedWorktreeIDs
            effects.append(
              .run { _ in
                await repositoryPersistence.savePinnedWorktreeIDs(pinnedWorktreeIDs)
              }
            )
          }
          if didUpdateWorktreeOrder {
            let worktreeOrderByRepository = state.worktreeOrderByRepository
            effects.append(
              .run { _ in
                await repositoryPersistence.saveWorktreeOrderByRepository(worktreeOrderByRepository)
              }
            )
          }
          return .merge(effects)
        }
        analyticsClient.capture("worktree_pinned", nil)
        state.pinnedWorktreeIDs.removeAll { $0 == worktreeID }
        state.pinnedWorktreeIDs.insert(worktreeID, at: 0)
        var didUpdateWorktreeOrder = false
        if let repositoryID = state.repositoryID(containing: worktreeID),
          var order = state.worktreeOrderByRepository[repositoryID]
        {
          order.removeAll { $0 == worktreeID }
          if order.isEmpty {
            state.worktreeOrderByRepository.removeValue(forKey: repositoryID)
          } else {
            state.worktreeOrderByRepository[repositoryID] = order
          }
          didUpdateWorktreeOrder = true
        }
        let pinnedWorktreeIDs = state.pinnedWorktreeIDs
        var effects: [Effect<Action>] = [
          .run { _ in
            await repositoryPersistence.savePinnedWorktreeIDs(pinnedWorktreeIDs)
          },
        ]
        if didUpdateWorktreeOrder {
          let worktreeOrderByRepository = state.worktreeOrderByRepository
          effects.append(
            .run { _ in
              await repositoryPersistence.saveWorktreeOrderByRepository(worktreeOrderByRepository)
            }
          )
        }
        return .merge(effects)

      case .unpinWorktree(let worktreeID):
        analyticsClient.capture("worktree_unpinned", nil)
        state.pinnedWorktreeIDs.removeAll { $0 == worktreeID }
        var didUpdateWorktreeOrder = false
        if let repositoryID = state.repositoryID(containing: worktreeID) {
          var order = state.worktreeOrderByRepository[repositoryID] ?? []
          order.removeAll { $0 == worktreeID }
          order.insert(worktreeID, at: 0)
          state.worktreeOrderByRepository[repositoryID] = order
          didUpdateWorktreeOrder = true
        }
        let pinnedWorktreeIDs = state.pinnedWorktreeIDs
        var effects: [Effect<Action>] = [
          .run { _ in
            await repositoryPersistence.savePinnedWorktreeIDs(pinnedWorktreeIDs)
          },
        ]
        if didUpdateWorktreeOrder {
          let worktreeOrderByRepository = state.worktreeOrderByRepository
          effects.append(
            .run { _ in
              await repositoryPersistence.saveWorktreeOrderByRepository(worktreeOrderByRepository)
            }
          )
        }
        return .merge(effects)

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
            try? await Task.sleep(for: .seconds(2.5))
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
          try? await Task.sleep(for: .seconds(2))
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

        var effects: [Effect<Action>] = []

        if !state.isMainWorktree(worktree), !state.isWorktreePinned(worktree) {
          let reordered = reorderedUnpinnedWorktreeIDs(
            for: worktreeID,
            in: repository,
            state: state
          )
          if state.worktreeOrderByRepository[repositoryID] != reordered {
            withAnimation(.snappy(duration: 0.2)) {
              state.worktreeOrderByRepository[repositoryID] = reordered
            }
            let worktreeOrderByRepository = state.worktreeOrderByRepository
            effects.append(
              .run { _ in
                await repositoryPersistence.saveWorktreeOrderByRepository(worktreeOrderByRepository)
              }
            )
          }
        }

        if effects.isEmpty {
          return .none
        }
        return .merge(effects)

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
          var seen = Set<String>()
          let branches =
            worktrees
            .map(\.name)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
          guard !branches.isEmpty else {
            return .none
          }
          let gitClient = gitClient
          let githubCLI = githubCLI
          let githubIntegration = githubIntegration
          return .run { send in
            guard await githubIntegration.isAvailable() else {
              return
            }
            guard let remoteInfo = await gitClient.remoteInfo(repositoryRootURL) else {
              return
            }
            let result = await Result {
              try await githubCLI.batchPullRequests(
                remoteInfo.host,
                remoteInfo.owner,
                remoteInfo.repo,
                branches
              )
            }
            switch result {
            case .success(let prsByBranch):
              for worktree in worktrees {
                let pullRequest = prsByBranch[worktree.name]
                await send(
                  .worktreePullRequestLoaded(worktreeID: worktree.id, pullRequest: pullRequest)
                )
              }
            case .failure:
              return
            }
          }
        }

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

      case .worktreePullRequestLoaded(let worktreeID, let pullRequest):
        let previousMerged =
          state.worktreeInfoByID[worktreeID]?.pullRequest?.state == "MERGED"
        let nextMerged = pullRequest?.state == "MERGED"
        updateWorktreePullRequest(
          worktreeID: worktreeID,
          pullRequest: pullRequest,
          state: &state
        )
        if state.automaticallyArchiveMergedWorktrees,
          !previousMerged,
          nextMerged,
          let repositoryID = state.repositoryID(containing: worktreeID),
          let repository = state.repositories[id: repositoryID],
          let worktree = repository.worktrees[id: worktreeID],
          !state.isMainWorktree(worktree),
          !state.isWorktreeArchived(worktreeID),
          !state.deletingWorktreeIDs.contains(worktreeID)
        {
          return .send(.archiveWorktreeConfirmed(worktreeID, repositoryID))
        }
        return .none

      case .pullRequestAction(let worktreeID, let action):
        guard let worktree = state.worktree(for: worktreeID),
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
        let branchName = pullRequest.headRefName ?? worktree.name
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

        case .openFailingCheckDetails:
          let checks = pullRequest.statusCheckRollup?.checks ?? []
          let detailsUrl = checks.first {
            $0.checkState == .failure && $0.detailsUrl != nil
          }?.detailsUrl
          guard let detailsUrl, let url = URL(string: detailsUrl) else {
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
            await send(.showToast(.inProgress("Marking PR ready…")))
            do {
              try await githubCLI.markPullRequestReady(worktreeRoot, pullRequest.number)
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
            let strategy = repositorySettings.pullRequestMergeStrategy
            await send(.showToast(.inProgress("Merging pull request…")))
            do {
              try await githubCLI.mergePullRequest(worktreeRoot, pullRequest.number, strategy)
              await send(.showToast(.success("Pull request merged")))
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
        guard !isEnabled else {
          return .none
        }
        let worktreeIDs = Array(state.worktreeInfoByID.keys)
        for worktreeID in worktreeIDs {
          updateWorktreePullRequest(
            worktreeID: worktreeID,
            pullRequest: nil,
            state: &state
          )
        }
        return .none

      case .setAutomaticallyArchiveMergedWorktrees(let isEnabled):
        state.automaticallyArchiveMergedWorktrees = isEnabled
        return .none

      case .openRepositorySettings(let repositoryID):
        return .send(.delegate(.openRepositorySettings(repositoryID)))

      case .alert(.dismiss):
        state.alert = nil
        return .none

      case .alert:
        return .none

      case .delegate:
        return .none
      }
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

  private func loadRepositoriesData(_ roots: [URL]) async -> ([Repository], [LoadFailure]) {
    var loaded: [Repository] = []
    var failures: [LoadFailure] = []
    for root in roots {
      let normalizedRoot = root.standardizedFileURL
      let rootID = normalizedRoot.path(percentEncoded: false)
      do {
        let worktrees = try await gitClient.worktrees(root)
        let name = Repository.name(for: normalizedRoot)
        let repository = Repository(
          id: rootID,
          rootURL: normalizedRoot,
          name: name,
          worktrees: IdentifiedArray(uniqueElements: worktrees)
        )
        loaded.append(repository)
      } catch {
        failures.append(LoadFailure(rootID: rootID, message: error.localizedDescription))
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
    let filteredSetupScriptIDs = state.pendingSetupScriptWorktreeIDs.filter {
      availableWorktreeIDs.contains($0)
    }
    let filteredFocusIDs = state.pendingTerminalFocusWorktreeIDs.filter {
      availableWorktreeIDs.contains($0)
    }
    let filteredWorktreeInfo = state.worktreeInfoByID.filter {
      availableWorktreeIDs.contains($0.key)
    }
    let identifiedRepositories = IdentifiedArray(uniqueElements: repositories)
    if animated {
      withAnimation {
        state.repositories = identifiedRepositories
        state.pendingWorktrees = filteredPendingWorktrees
        state.deletingWorktreeIDs = filteredDeletingIDs
        state.pendingSetupScriptWorktreeIDs = filteredSetupScriptIDs
        state.pendingTerminalFocusWorktreeIDs = filteredFocusIDs
        state.worktreeInfoByID = filteredWorktreeInfo
      }
    } else {
      state.repositories = identifiedRepositories
      state.pendingWorktrees = filteredPendingWorktrees
      state.deletingWorktreeIDs = filteredDeletingIDs
      state.pendingSetupScriptWorktreeIDs = filteredSetupScriptIDs
      state.pendingTerminalFocusWorktreeIDs = filteredFocusIDs
      state.worktreeInfoByID = filteredWorktreeInfo
    }
    let didPrunePinned = prunePinnedWorktreeIDs(state: &state)
    let didPruneRepositoryOrder = pruneRepositoryOrderIDs(roots: roots, state: &state)
    let didPruneWorktreeOrder = pruneWorktreeOrderByRepository(roots: roots, state: &state)
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
        isSelectionValid(state.lastFocusedWorktreeID, state: state)
      {
        state.selection = state.lastFocusedWorktreeID.map(SidebarSelection.worktree)
      }
    }
    if state.selection == nil, state.shouldSelectFirstAfterReload {
      state.selection = firstAvailableWorktreeID(from: repositories, state: state)
        .map(SidebarSelection.worktree)
      state.shouldSelectFirstAfterReload = false
    }
    return ApplyRepositoriesResult(
      didPrunePinned: didPrunePinned,
      didPruneRepositoryOrder: didPruneRepositoryOrder,
      didPruneWorktreeOrder: didPruneWorktreeOrder,
      didPruneArchivedWorktreeIDs: didPruneArchivedWorktreeIDs
    )
  }

  private func messageAlert(title: String, message: String) -> AlertState<Alert> {
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

  private func confirmationAlertForRepositoryRemoval(
    repositoryID: Repository.ID,
    state: State
  ) -> AlertState<Alert>? {
    guard let repository = state.repositories[id: repositoryID] else {
      return nil
    }
    return AlertState {
      TextState("Remove repository?")
    } actions: {
      ButtonState(role: .destructive, action: .confirmRemoveRepository(repository.id)) {
        TextState("Remove repository")
      }
      ButtonState(role: .cancel) {
        TextState("Cancel")
      }
    } message: {
      TextState(
        "This removes the repository from Supacode. "
          + "Worktrees and the main repository folder stay on disk."
      )
    }
  }

  private func selectionDidChange(
    previousSelectionID: Worktree.ID?,
    previousSelectedWorktree: Worktree?,
    selectedWorktreeID: Worktree.ID?,
    selectedWorktree: Worktree?
  ) -> Bool {
    if previousSelectionID != selectedWorktreeID {
      return true
    }
    if previousSelectedWorktree?.workingDirectory != selectedWorktree?.workingDirectory {
      return true
    }
    if previousSelectedWorktree?.repositoryRootURL != selectedWorktree?.repositoryRootURL {
      return true
    }
    return false
  }
}

extension RepositoriesFeature.State {
  var selectedWorktreeID: Worktree.ID? {
    selection?.worktreeID
  }

  var isShowingArchivedWorktrees: Bool {
    selection == .archivedWorktrees
  }

  var archivedWorktreeIDSet: Set<Worktree.ID> {
    Set(archivedWorktreeIDs)
  }

  func isWorktreeArchived(_ id: Worktree.ID) -> Bool {
    archivedWorktreeIDSet.contains(id)
  }

  func worktreeInfo(for worktreeID: Worktree.ID) -> WorktreeInfoEntry? {
    worktreeInfoByID[worktreeID]
  }

  func worktreesForInfoWatcher() -> [Worktree] {
    let worktrees = repositories.flatMap(\.worktrees)
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
      return !removingRepositoryIDs.contains(repository.id)
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

  func pendingWorktree(for id: Worktree.ID?) -> PendingWorktree? {
    guard let id else { return nil }
    return pendingWorktrees.first(where: { $0.id == id })
  }

  func shouldFocusTerminal(for worktreeID: Worktree.ID) -> Bool {
    pendingTerminalFocusWorktreeIDs.contains(worktreeID)
  }

  private func makePendingWorktreeRow(_ pending: PendingWorktree) -> WorktreeRowModel {
    let isDeleting = removingRepositoryIDs.contains(pending.repositoryID)
    return WorktreeRowModel(
      id: pending.id,
      repositoryID: pending.repositoryID,
      name: pending.name,
      detail: pending.detail,
      info: worktreeInfo(for: pending.id),
      isPinned: false,
      isMainWorktree: false,
      isPending: true,
      isDeleting: isDeleting,
      isRemovable: false
    )
  }

  private func makeWorktreeRow(
    _ worktree: Worktree,
    repositoryID: Repository.ID,
    isPinned: Bool,
    isMainWorktree: Bool
  ) -> WorktreeRowModel {
    let isDeleting =
      removingRepositoryIDs.contains(repositoryID)
      || deletingWorktreeIDs.contains(worktree.id)
    return WorktreeRowModel(
      id: worktree.id,
      repositoryID: repositoryID,
      name: worktree.name,
      detail: worktree.detail,
      info: worktreeInfo(for: worktree.id),
      isPinned: isPinned,
      isMainWorktree: isMainWorktree,
      isPending: false,
      isDeleting: isDeleting,
      isRemovable: !isDeleting
    )
  }

  func selectedRow(for id: Worktree.ID?) -> WorktreeRowModel? {
    guard let id else { return nil }
    if isWorktreeArchived(id) {
      return nil
    }
    if let pending = pendingWorktree(for: id) {
      return makePendingWorktreeRow(pending)
    }
    for repository in repositories {
      if let worktree = repository.worktrees[id: id] {
        return makeWorktreeRow(
          worktree,
          repositoryID: repository.id,
          isPinned: pinnedWorktreeIDs.contains(worktree.id),
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
    for id in repositoryOrderIDs {
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
    let archivedSet = archivedWorktreeIDSet
    return pinnedWorktreeIDs.filter { id in
      if archivedSet.contains(id) {
        return false
      }
      if let worktree = repository.worktrees[id: id] {
        return !isMainWorktree(worktree)
      }
      return false
    }
  }

  func orderedPinnedWorktrees(in repository: Repository) -> [Worktree] {
    orderedPinnedWorktreeIDs(in: repository).compactMap { repository.worktrees[id: $0] }
  }

  func replacingPinnedWorktreeIDs(
    in repository: Repository,
    with reordered: [Worktree.ID]
  ) -> [Worktree.ID] {
    let repoPinnedIDs = Set(orderedPinnedWorktreeIDs(in: repository))
    var iterator = reordered.makeIterator()
    return pinnedWorktreeIDs.map { id in
      if repoPinnedIDs.contains(id) {
        return iterator.next() ?? id
      }
      return id
    }
  }

  func orderedUnpinnedWorktreeIDs(in repository: Repository) -> [Worktree.ID] {
    let mainID = repository.worktrees.first(where: { isMainWorktree($0) })?.id
    let pinnedSet = Set(pinnedWorktreeIDs)
    let archivedSet = archivedWorktreeIDSet
    let available = repository.worktrees.filter { worktree in
      worktree.id != mainID
        && !pinnedSet.contains(worktree.id)
        && !archivedSet.contains(worktree.id)
    }
    let orderedIDs = worktreeOrderByRepository[repository.id] ?? []
    let availableIDs = Set(available.map(\.id))
    let orderedIDSet = Set(orderedIDs)
    var seen: Set<Worktree.ID> = []
    var missing: [Worktree.ID] = []
    for worktree in available where !orderedIDSet.contains(worktree.id) {
      if seen.insert(worktree.id).inserted {
        missing.append(worktree.id)
      }
    }
    var ordered: [Worktree.ID] = []
    for id in orderedIDs {
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
    pinnedWorktreeIDs.contains(worktree.id)
  }

  var confirmWorktreeAlert: RepositoriesFeature.Alert? {
    guard let alert else { return nil }
    for button in alert.buttons {
      if case .confirmArchiveWorktree(let worktreeID, let repositoryID)? = button.action.action {
        return .confirmArchiveWorktree(worktreeID, repositoryID)
      }
      if case .confirmDeleteWorktree(let worktreeID, let repositoryID)? = button.action.action {
        return .confirmDeleteWorktree(worktreeID, repositoryID)
      }
      if case .confirmDeleteWorktrees(let targets)? = button.action.action {
        return .confirmDeleteWorktrees(targets)
      }
    }
    return nil
  }

  func isRemovingRepository(_ repository: Repository) -> Bool {
    removingRepositoryIDs.contains(repository.id)
  }

  func worktreeRowSections(in repository: Repository) -> WorktreeRowSections {
    let mainWorktree = repository.worktrees.first(where: { isMainWorktree($0) })
    let pinnedWorktrees = orderedPinnedWorktrees(in: repository)
    let unpinnedWorktrees = orderedUnpinnedWorktrees(in: repository)
    let pendingEntries = pendingWorktrees.filter { $0.repositoryID == repository.id }
    let mainRow: WorktreeRowModel? =
      if let mainWorktree, !isWorktreeArchived(mainWorktree.id) {
        makeWorktreeRow(
          mainWorktree,
          repositoryID: repository.id,
          isPinned: false,
          isMainWorktree: true
        )
      } else {
        nil
      }
    var pinnedRows: [WorktreeRowModel] = []
    for worktree in pinnedWorktrees {
      pinnedRows.append(
        makeWorktreeRow(
          worktree,
          repositoryID: repository.id,
          isPinned: true,
          isMainWorktree: false
        )
      )
    }
    var pendingRows: [WorktreeRowModel] = []
    for pending in pendingEntries {
      pendingRows.append(makePendingWorktreeRow(pending))
    }
    var unpinnedRows: [WorktreeRowModel] = []
    for worktree in unpinnedWorktrees {
      unpinnedRows.append(
        makeWorktreeRow(
          worktree,
          repositoryID: repository.id,
          isPinned: false,
          isMainWorktree: false
        )
      )
    }
    return WorktreeRowSections(
      main: mainRow,
      pinned: pinnedRows,
      pending: pendingRows,
      unpinned: unpinnedRows
    )
  }

  func worktreeRows(in repository: Repository) -> [WorktreeRowModel] {
    let sections = worktreeRowSections(in: repository)
    return sections.allRows
  }

  func orderedWorktreeRows() -> [WorktreeRowModel] {
    let repositoriesByID = Dictionary(uniqueKeysWithValues: repositories.map { ($0.id, $0) })
    return orderedRepositoryIDs()
      .compactMap { repositoriesByID[$0] }
      .flatMap { worktreeRows(in: $0) }
  }
}

struct WorktreeRowSections {
  let main: WorktreeRowModel?
  let pinned: [WorktreeRowModel]
  let pending: [WorktreeRowModel]
  let unpinned: [WorktreeRowModel]

  var allRows: [WorktreeRowModel] {
    var rows: [WorktreeRowModel] = []
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
  let didUpdatePinned: Bool
  let didUpdateOrder: Bool
  let worktree: Worktree?
}

private func removePendingWorktree(_ id: String, state: inout RepositoriesFeature.State) {
  state.pendingWorktrees.removeAll { $0.id == id }
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
  state: inout RepositoriesFeature.State
) -> FailedWorktreeCleanup {
  guard let name, !name.isEmpty else {
    return FailedWorktreeCleanup(
      didRemoveWorktree: false,
      didUpdatePinned: false,
      didUpdateOrder: false,
      worktree: nil
    )
  }
  let repositoryRootURL = URL(fileURLWithPath: repositoryID).standardizedFileURL
  let baseDirectory = SupacodePaths.repositoryDirectory(for: repositoryRootURL)
  let worktreeURL = baseDirectory.appending(path: name, directoryHint: .isDirectory)
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
    didUpdatePinned: cleanup.didUpdatePinned,
    didUpdateOrder: cleanup.didUpdateOrder,
    worktree: worktree
  )
}

private struct WorktreeCleanupStateResult {
  let didRemoveWorktree: Bool
  let didUpdatePinned: Bool
  let didUpdateOrder: Bool
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
  state.deletingWorktreeIDs.remove(worktreeID)
  state.worktreeInfoByID.removeValue(forKey: worktreeID)
  let didUpdatePinned = state.pinnedWorktreeIDs.contains(worktreeID)
  if didUpdatePinned {
    state.pinnedWorktreeIDs.removeAll { $0 == worktreeID }
  }
  var didUpdateOrder = false
  if var order = state.worktreeOrderByRepository[repositoryID] {
    let countBefore = order.count
    order.removeAll { $0 == worktreeID }
    if order.count != countBefore {
      didUpdateOrder = true
      if order.isEmpty {
        state.worktreeOrderByRepository.removeValue(forKey: repositoryID)
      } else {
        state.worktreeOrderByRepository[repositoryID] = order
      }
    }
  }
  return WorktreeCleanupStateResult(
    didRemoveWorktree: didRemoveWorktree,
    didUpdatePinned: didUpdatePinned,
    didUpdateOrder: didUpdateOrder
  )
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
  if isSelectionValid(id, state: state) {
    state.selection = id.map(SidebarSelection.worktree)
  } else {
    state.selection = nil
  }
}

private func isSelectionValid(
  _ id: Worktree.ID?,
  state: RepositoriesFeature.State
) -> Bool {
  state.selectedRow(for: id) != nil
}

private func repositoryForWorktreeCreation(
  _ state: RepositoriesFeature.State
) -> Repository? {
  if let selectedWorktreeID = state.selectedWorktreeID {
    if let pending = state.pendingWorktree(for: selectedWorktreeID) {
      return state.repositories[id: pending.repositoryID]
    }
    for repository in state.repositories
    where repository.worktrees[id: selectedWorktreeID] != nil {
      return repository
    }
  }
  if state.repositories.count == 1 {
    return state.repositories.first
  }
  return nil
}

private func prunePinnedWorktreeIDs(state: inout RepositoriesFeature.State) -> Bool {
  let availableIDs = Set(state.repositories.flatMap { $0.worktrees.map(\.id) })
  let mainIDs = Set(
    state.repositories.compactMap { repository in
      repository.worktrees.first(where: { state.isMainWorktree($0) })?.id
    }
  )
  let archivedSet = state.archivedWorktreeIDSet
  let pruned = state.pinnedWorktreeIDs.filter {
    availableIDs.contains($0)
      && !mainIDs.contains($0)
      && !archivedSet.contains($0)
  }
  if pruned != state.pinnedWorktreeIDs {
    state.pinnedWorktreeIDs = pruned
    return true
  }
  return false
}

private func pruneRepositoryOrderIDs(
  roots: [URL],
  state: inout RepositoriesFeature.State
) -> Bool {
  let rootIDs = roots.map { $0.standardizedFileURL.path(percentEncoded: false) }
  let availableIDs = Set(rootIDs + state.repositories.map(\.id))
  let pruned = state.repositoryOrderIDs.filter { availableIDs.contains($0) }
  if pruned != state.repositoryOrderIDs {
    state.repositoryOrderIDs = pruned
    return true
  }
  return false
}

private func pruneWorktreeOrderByRepository(
  roots: [URL],
  state: inout RepositoriesFeature.State
) -> Bool {
  let rootIDs = Set(roots.map { $0.standardizedFileURL.path(percentEncoded: false) })
  let repositoriesByID = Dictionary(uniqueKeysWithValues: state.repositories.map { ($0.id, $0) })
  let pinnedSet = Set(state.pinnedWorktreeIDs)
  let archivedSet = state.archivedWorktreeIDSet
  var pruned: [Repository.ID: [Worktree.ID]] = [:]
  for (repoID, order) in state.worktreeOrderByRepository {
    guard let repository = repositoriesByID[repoID] else {
      if rootIDs.contains(repoID), !order.isEmpty {
        pruned[repoID] = order
      }
      continue
    }
    let mainID = repository.worktrees.first(where: { state.isMainWorktree($0) })?.id
    let availableIDs = Set(repository.worktrees.map(\.id))
    var seen: Set<Worktree.ID> = []
    var filtered: [Worktree.ID] = []
    for id in order {
      if availableIDs.contains(id),
        id != mainID,
        !pinnedSet.contains(id),
        !archivedSet.contains(id),
        seen.insert(id).inserted
      {
        filtered.append(id)
      }
    }
    if !filtered.isEmpty {
      pruned[repoID] = filtered
    }
  }
  if pruned != state.worktreeOrderByRepository {
    state.worktreeOrderByRepository = pruned
    return true
  }
  return false
}

private func pruneArchivedWorktreeIDs(
  availableWorktreeIDs: Set<Worktree.ID>,
  state: inout RepositoriesFeature.State
) -> Bool {
  let pruned = state.archivedWorktreeIDs.filter { availableWorktreeIDs.contains($0) }
  if pruned != state.archivedWorktreeIDs {
    state.archivedWorktreeIDs = pruned
    return true
  }
  return false
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
