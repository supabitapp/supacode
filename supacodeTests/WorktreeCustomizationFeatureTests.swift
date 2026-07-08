import ComposableArchitecture
import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct WorktreeCustomizationFeatureTests {
  private func makeState(
    title: String = "",
    color: RepositoryColor? = nil,
  ) -> WorktreeCustomizationFeature.State {
    WorktreeCustomizationFeature.State(
      worktreeID: "wt-1",
      repositoryID: "/tmp/repo",
      defaultName: "feature/x",
      title: title,
      color: color,
    )
  }

  @Test func saveTrimsTitleAndForwardsValues() async {
    let store = TestStore(initialState: makeState(title: "  Spicy  ", color: .blue)) {
      WorktreeCustomizationFeature()
    }

    await store.send(.saveButtonTapped)
    await store.receive(
      .delegate(
        .save(worktreeID: "wt-1", repositoryID: "/tmp/repo", title: "Spicy", color: .blue),
      ))
  }

  @Test func saveDropsTitleOnlyWhenEmptyAfterTrim() async {
    let store = TestStore(initialState: makeState(title: "   ")) {
      WorktreeCustomizationFeature()
    }

    await store.send(.saveButtonTapped)
    await store.receive(
      .delegate(.save(worktreeID: "wt-1", repositoryID: "/tmp/repo", title: nil, color: nil)),
    )
  }

  @Test func savePreservesTitleEvenWhenItMatchesDefault() async {
    // Typing the default name locks it in as an explicit override (doesn't collapse to nil).
    let store = TestStore(initialState: makeState(title: "feature/x")) {
      WorktreeCustomizationFeature()
    }

    await store.send(.saveButtonTapped)
    await store.receive(
      .delegate(.save(worktreeID: "wt-1", repositoryID: "/tmp/repo", title: "feature/x", color: nil)),
    )
  }

  @Test func cancelDelegatesCancel() async {
    let store = TestStore(initialState: makeState()) {
      WorktreeCustomizationFeature()
    }

    await store.send(.cancelButtonTapped)
    await store.receive(.delegate(.cancel))
  }
}
