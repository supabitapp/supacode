import ComposableArchitecture
import Foundation

/// Message shown in the deeplink confirmation dialog.
enum DeeplinkConfirmationMessage: Equatable, Sendable {
  /// A literal command that will be executed in the terminal.
  case command(String)
  /// A descriptive confirmation prompt for destructive actions.
  case confirmation(String)

  var text: String {
    switch self {
    case .command(let value), .confirmation(let value):
      return value
    }
  }
}

@Reducer
struct DeeplinkInputConfirmationFeature {
  @ObservableState
  struct State: Equatable {
    let worktreeID: Worktree.ID
    let worktreeName: String
    let repositoryName: String?
    /// Display text shown to the user.
    let message: DeeplinkConfirmationMessage
    let action: Deeplink.WorktreeAction
    var alwaysAllow: Bool = false
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)
    case runTapped
    case cancelTapped
    case delegate(Delegate)
  }

  @CasePathable
  enum Delegate: Equatable {
    case confirm(worktreeID: Worktree.ID, action: Deeplink.WorktreeAction, alwaysAllow: Bool)
    case cancel
  }

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none
      case .runTapped:
        return .send(
          .delegate(.confirm(worktreeID: state.worktreeID, action: state.action, alwaysAllow: state.alwaysAllow))
        )
      case .cancelTapped:
        return .send(.delegate(.cancel))
      case .delegate:
        return .none
      }
    }
  }
}
