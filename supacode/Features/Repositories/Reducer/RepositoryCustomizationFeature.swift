import ComposableArchitecture
import Foundation
import SwiftUI

@Reducer
struct RepositoryCustomizationFeature {
  @ObservableState
  struct State: Equatable {
    let repositoryID: Repository.ID
    let defaultName: String
    var title: String
    var color: RepositoryColor?
    /// Mirror of `color` parsed into a SwiftUI `Color` so the
    /// system `ColorPicker` can bind without a manual conversion at
    /// every render. `nil` means "no tint" — the ColorPicker is
    /// hidden behind the "Custom" swatch in that state.
    var customColor: Color
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)
    case selectColor(RepositoryColor?)
    case cancelButtonTapped
    case saveButtonTapped
    case delegate(Delegate)
  }

  @CasePathable
  enum Delegate: Equatable {
    case cancel
    case save(repositoryID: Repository.ID, title: String?, color: RepositoryColor?)
  }

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding(\.customColor):
        // ColorPicker edits flow into `state.color` as `.custom(hex)`.
        // BindingReducer only fires for view-driven writes, so the
        // mirror updates from `.selectColor` (predefined picks)
        // don't loop back through this branch. The trade-off: an
        // explicit drag in the panel demotes `.red` to a
        // sRGB-quantized hex, which is correct intent capture but
        // loses the predefined label.
        if let custom = RepositoryColor.custom(from: state.customColor) {
          state.color = custom
        }
        return .none

      case .binding:
        return .none

      case .selectColor(let color):
        state.color = color
        if let color {
          state.customColor = color.color
        }
        return .none

      case .cancelButtonTapped:
        return .send(.delegate(.cancel))

      case .saveButtonTapped:
        let trimmed = state.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = trimmed.isEmpty || trimmed == state.defaultName ? nil : trimmed
        return .send(
          .delegate(
            .save(
              repositoryID: state.repositoryID,
              title: resolvedTitle,
              color: state.color
            )
          )
        )

      case .delegate:
        return .none
      }
    }
  }
}
