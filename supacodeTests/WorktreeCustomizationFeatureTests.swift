import ComposableArchitecture
import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
@Suite(.serialized)
struct WorktreeCustomizationFeatureTests {
  private func makeState(
    title: String = "",
    subtitle: String = "",
    color: RepositoryColor? = nil,
  ) -> WorktreeCustomizationFeature.State {
    WorktreeCustomizationFeature.State(
      worktreeID: "wt-1",
      repositoryID: "/tmp/repo",
      defaultName: "feature/x",
      title: title,
      subtitle: subtitle,
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
        .save(worktreeID: "wt-1", repositoryID: "/tmp/repo", title: "Spicy", subtitle: nil, color: .blue),
      ))
  }

  @Test func saveTrimsSubtitleAndForwardsValue() async {
    let store = TestStore(initialState: makeState(subtitle: "  Spicy Sub  ")) {
      WorktreeCustomizationFeature()
    }

    await store.send(.saveButtonTapped)
    await store.receive(
      .delegate(.save(worktreeID: "wt-1", repositoryID: "/tmp/repo", title: nil, subtitle: "Spicy Sub", color: nil)),
    )
  }

  @Test func saveDropsTitleAndSubtitleWhenEmptyAfterTrim() async {
    let store = TestStore(initialState: makeState(title: "   ", subtitle: "   ")) {
      WorktreeCustomizationFeature()
    }

    await store.send(.saveButtonTapped)
    await store.receive(
      .delegate(.save(worktreeID: "wt-1", repositoryID: "/tmp/repo", title: nil, subtitle: nil, color: nil)),
    )
  }

  @Test func savePreservesTitleAndSubtitleEvenWhenTheyMatchDefaults() async {
    // Typing the default names locks them in as explicit overrides (doesn't collapse to nil).
    let store = TestStore(initialState: makeState(title: "feature/x", subtitle: "Default")) {
      WorktreeCustomizationFeature()
    }

    await store.send(.saveButtonTapped)
    await store.receive(
      .delegate(
        .save(worktreeID: "wt-1", repositoryID: "/tmp/repo", title: "feature/x", subtitle: "Default", color: nil)),
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
