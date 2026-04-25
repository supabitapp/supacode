import ComposableArchitecture
import Foundation
import SwiftUI
import Testing

@testable import supacode

@MainActor
@Suite(.serialized)
struct RepositoryCustomizationFeatureTests {
  private func makeState(
    title: String = "",
    color: RepositoryColor? = nil,
  ) -> RepositoryCustomizationFeature.State {
    RepositoryCustomizationFeature.State(
      repositoryID: "/tmp/repo",
      defaultName: "repo",
      title: title,
      color: color,
      customColor: color?.color ?? .accentColor,
    )
  }

  @Test func saveTrimsTitleAndForwardsValues() async {
    let store = TestStore(initialState: makeState(title: "  Custom Title  ", color: .blue)) {
      RepositoryCustomizationFeature()
    }

    await store.send(.saveButtonTapped)
    await store.receive(
      .delegate(
        .save(repositoryID: "/tmp/repo", title: "Custom Title", color: .blue),
      ))
  }

  @Test func saveDropsTitleWhenEmptyOrMatchesDefault() async {
    let store = TestStore(initialState: makeState(title: "  repo  ")) {
      RepositoryCustomizationFeature()
    }

    await store.send(.saveButtonTapped)
    await store.receive(
      .delegate(.save(repositoryID: "/tmp/repo", title: nil, color: nil)),
    )
  }

  @Test func selectColorMirrorsCustomColor() async {
    let store = TestStore(initialState: makeState()) {
      RepositoryCustomizationFeature()
    }

    await store.send(.selectColor(.red)) {
      $0.color = .red
      $0.customColor = RepositoryColor.red.color
    }
  }

  @Test func selectNilColorClearsTint() async {
    let store = TestStore(initialState: makeState(color: .green)) {
      RepositoryCustomizationFeature()
    }

    await store.send(.selectColor(nil)) {
      $0.color = nil
    }
  }

  @Test func cancelDelegatesCancel() async {
    let store = TestStore(initialState: makeState()) {
      RepositoryCustomizationFeature()
    }

    await store.send(.cancelButtonTapped)
    await store.receive(.delegate(.cancel))
  }

  @Test func bindingPromotesCustomColorChangeToCustomCase() async {
    // ColorPicker drags drive `state.color` to `.custom(hex)` via
    // the binding. `BindingReducer` only fires for view-driven
    // writes, so the `.selectColor` mirror updates from predefined
    // picks don't loop back through this branch.
    let store = TestStore(initialState: makeState()) {
      RepositoryCustomizationFeature()
    }

    let next = Color(nsColor: NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
    await store.send(.set(\.customColor, next)) {
      $0.customColor = next
      $0.color = RepositoryColor.custom(from: next)
    }
  }
}
