import ComposableArchitecture
import Foundation
import Testing

@testable import SupacodeSettingsShared
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

  @Test func cancelDelegatesCancel() async {
    let store = TestStore(initialState: makeState()) {
      RepositoryCustomizationFeature()
    }

    await store.send(.cancelButtonTapped)
    await store.receive(.delegate(.cancel))
  }
}
