import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

@Reducer
struct RenameBranchFeature {
  @ObservableState
  struct State: Equatable, Identifiable {
    let worktreeID: Worktree.ID
    let repositoryID: Repository.ID
    let repositoryRootURL: URL
    let host: RemoteHost?
    let currentName: String
    var newName: String
    var isSubmitting = false
    var validationMessage: String?

    var id: Worktree.ID { worktreeID }

    init(
      worktreeID: Worktree.ID,
      repositoryID: Repository.ID,
      repositoryRootURL: URL,
      host: RemoteHost?,
      currentName: String
    ) {
      self.worktreeID = worktreeID
      self.repositoryID = repositoryID
      self.repositoryRootURL = repositoryRootURL
      self.host = host
      self.currentName = currentName
      self.newName = currentName
    }

    var trimmedName: String {
      newName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isUnchanged: Bool {
      trimmedName == currentName
    }

    var canSubmit: Bool {
      !isSubmitting && !trimmedName.isEmpty && !isUnchanged
    }
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)
    case cancelButtonTapped
    case renameButtonTapped
    case renameFailed(String)
    case delegate(Delegate)
  }

  @CasePathable
  enum Delegate: Equatable {
    case cancel
    case renamed(worktreeID: Worktree.ID, repositoryID: Repository.ID, newName: String)
  }

  @Dependency(GitClientDependency.self) private var gitClient

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding(\.newName):
        state.validationMessage = nil
        return .none

      case .binding:
        return .none

      case .cancelButtonTapped:
        return .send(.delegate(.cancel))

      case .renameButtonTapped:
        guard state.canSubmit else { return .none }
        let trimmed = state.trimmedName
        let oldName = state.currentName
        let repoRoot = state.repositoryRootURL
        let worktreeID = state.worktreeID
        let repositoryID = state.repositoryID
        let gitClient = state.host.map { GitClientDependency.ssh(host: $0) } ?? gitClient
        state.isSubmitting = true
        state.validationMessage = nil
        return .run { send in
          let isValid = await gitClient.isValidBranchName(trimmed, repoRoot)
          guard isValid else {
            await send(.renameFailed("Enter a valid git branch name and try again."))
            return
          }
          // Lowercased dedup matches git's rejection on default-APFS volumes.
          // Inverted second clause lets a case-only rename of the same branch
          // fall through to git, which is the only place that can decide.
          let existing = (try? await gitClient.localBranchNames(repoRoot)) ?? []
          if existing.contains(trimmed.lowercased()), trimmed.lowercased() != oldName.lowercased() {
            await send(.renameFailed("A branch named '\(trimmed)' already exists."))
            return
          }
          do {
            try await gitClient.renameBranch(oldName, trimmed, repoRoot)
          } catch {
            await send(.renameFailed(Self.friendlyRenameError(from: error, target: trimmed)))
            return
          }
          await send(
            .delegate(
              .renamed(worktreeID: worktreeID, repositoryID: repositoryID, newName: trimmed)
            )
          )
        }

      case .renameFailed(let message):
        state.isSubmitting = false
        state.validationMessage = message
        return .none

      case .delegate:
        return .none
      }
    }
  }

  /// Rewrites common `git branch -m` stderr into one-line user messages.
  /// The fallback returns only the stderr body, never the invoked command
  /// (which contains the absolute repo path).
  static func friendlyRenameError(from error: any Error, target: String) -> String {
    let body: String
    if case GitClientError.commandFailed(_, let message) = error {
      body = message
    } else {
      body = error.localizedDescription
    }
    let lower = body.lowercased()
    if lower.contains("already exists") {
      return "A branch named '\(target)' already exists."
    }
    if lower.contains("cannot be renamed"), lower.contains("checked out") {
      return "This branch is checked out in another worktree. Switch that worktree to a different branch and try again."
    }
    if lower.contains("not a valid branch name") || lower.contains("not a valid ref") {
      return "Git rejected '\(target)' as an invalid branch name."
    }
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "git rejected the rename." : trimmed
  }
}
