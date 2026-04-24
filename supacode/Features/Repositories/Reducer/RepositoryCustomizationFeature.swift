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
    case selectCustomColor
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
        // Re-flow ColorPicker edits back into the canonical `color`
        // payload so save delegates the right value without a
        // separate "is custom mode active?" flag. Gated on
        // `isCustom`: predefined picks mirror their swatch into
        // `customColor` for ColorPicker preview, but a stray write
        // back from SwiftUI (sRGB-quantization round-trip) must not
        // demote `.red` to `.custom("#FF3B30")` — so the promotion
        // only fires when the user is already editing in custom
        // mode.
        guard state.color?.isCustom == true else {
          return .none
        }
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

      case .selectCustomColor:
        // Explicit entry into custom mode — fires when the user
        // taps the rainbow swatch. Gating the `binding(\.customColor)`
        // arm on `isCustom == true` blocks SwiftUI write-backs from
        // demoting a predefined pick, but the entry path needs its
        // own action so the user can switch from `.red` to a
        // `.custom` hex without first dragging in the system panel.
        if state.color?.isCustom != true,
          let custom = RepositoryColor.custom(from: state.customColor)
        {
          state.color = custom
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
