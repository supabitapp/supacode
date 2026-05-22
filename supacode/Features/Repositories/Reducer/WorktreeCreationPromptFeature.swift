import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

@Reducer
struct WorktreeCreationPromptFeature {
  @ObservableState
  struct State: Equatable {
    let repositoryID: Repository.ID
    let repositoryName: String
    /// The resolved auto base ref (e.g. `origin/main`), kept as the default.
    let automaticBaseRef: String
    /// Local branch matching the default ref (e.g. `main`), surfaced as a quick
    /// pick. Cleared once the inventory confirms no such local branch exists.
    var defaultBranch: String?
    /// Configured remote names, used to classify the selected ref as local or remote.
    let remoteNames: [String]
    /// Pre-built local + per-remote branch menu trees; `nil` while still loading.
    var branchMenu: BaseRefBranchMenu?
    var branchName: String
    var selectedBaseRef: String?
    var fetchOrigin: Bool
    var validationMessage: String?
    var isValidating = false

    /// Label shown on the base-ref menu button.
    var baseRefMenuLabel: String {
      if let selectedBaseRef, !selectedBaseRef.isEmpty {
        return selectedBaseRef
      }
      return automaticBaseRef.isEmpty ? "Auto" : automaticBaseRef
    }

    var isLoadingBranches: Bool {
      branchMenu == nil
    }

    /// Whether the effective base ref (selection, or the auto ref when unset)
    /// has no remote to fetch from. A name-prefix heuristic, not a true ref
    /// classification: anything without a known `<remote>/` prefix (a local
    /// branch, but also a tag, SHA, or HEAD) counts as "nothing to fetch",
    /// which is exactly when the fetch toggle should be off.
    var isSelectedBaseRefLocal: Bool {
      let ref = selectedBaseRef ?? automaticBaseRef
      guard !ref.isEmpty else { return true }
      return GitReferenceQueries.localBranchName(fromRemoteRef: ref, remoteNames: remoteNames) == nil
    }
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)
    case baseRefSelected(String?)
    case cancelButtonTapped
    case createButtonTapped
    case setValidationMessage(String?)
    case setValidating(Bool)
    case delegate(Delegate)
  }

  @CasePathable
  enum Delegate: Equatable {
    case cancel
    case submit(repositoryID: Repository.ID, branchName: String, baseRef: String?, fetchOrigin: Bool)
  }

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        state.validationMessage = nil
        return .none

      case .baseRefSelected(let ref):
        state.selectedBaseRef = ref
        state.validationMessage = nil
        return .none

      case .cancelButtonTapped:
        return .send(.delegate(.cancel))

      case .createButtonTapped:
        let trimmed = state.branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
          state.validationMessage = "Branch name required."
          return .none
        }
        guard !trimmed.contains(where: \.isWhitespace) else {
          state.validationMessage = "Branch names can't contain spaces."
          return .none
        }
        state.validationMessage = nil
        return .send(
          .delegate(
            .submit(
              repositoryID: state.repositoryID,
              branchName: trimmed,
              baseRef: state.selectedBaseRef,
              // Match the disabled toggle: a local base ref has nothing to fetch.
              fetchOrigin: state.isSelectedBaseRefLocal ? false : state.fetchOrigin
            )
          )
        )

      case .setValidationMessage(let message):
        state.validationMessage = message
        return .none

      case .setValidating(let isValidating):
        state.isValidating = isValidating
        return .none

      case .delegate:
        return .none
      }
    }
  }
}
