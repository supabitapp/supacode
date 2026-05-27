import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

@Reducer
struct WorktreeCustomizationFeature {
  @ObservableState
  struct State: Equatable {
    let worktreeID: Worktree.ID
    let repositoryID: Repository.ID
    let defaultName: String
    var title: String
    var color: RepositoryColor?
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)
    case cancelButtonTapped
    case saveButtonTapped
    case delegate(Delegate)
  }

  @CasePathable
  enum Delegate: Equatable {
    case cancel
    case save(
      worktreeID: Worktree.ID,
      repositoryID: Repository.ID,
      title: String?,
      color: RepositoryColor?,
    )
  }

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .cancelButtonTapped:
        return .send(.delegate(.cancel))

      case .saveButtonTapped:
        let trimmed = state.title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Preserve the user's input verbatim; typing the default name "locks in" the current name
        // as a real override rather than silently collapsing to nil.
        let resolvedTitle = trimmed.isEmpty ? nil : trimmed
        return .send(
          .delegate(
            .save(
              worktreeID: state.worktreeID,
              repositoryID: state.repositoryID,
              title: resolvedTitle,
              color: state.color,
            )
          )
        )

      case .delegate:
        return .none
      }
    }
  }
}
