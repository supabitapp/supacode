import ComposableArchitecture
import Foundation
import Testing

@testable import supacode

@MainActor
struct WorktreeCreationPromptFeatureTests {
  private func makeState(
    automaticBaseRef: String = "origin/main",
    defaultBranch: String? = "main",
    remoteNames: [String] = ["origin"],
    branchMenu: BaseRefBranchMenu? = nil,
    selectedBaseRef: String? = nil
  ) -> WorktreeCreationPromptFeature.State {
    WorktreeCreationPromptFeature.State(
      repositoryID: "/tmp/repo/",
      repositoryName: "repo",
      automaticBaseRef: automaticBaseRef,
      defaultBranch: defaultBranch,
      remoteNames: remoteNames,
      branchMenu: branchMenu,
      branchName: "",
      selectedBaseRef: selectedBaseRef,
      fetchOrigin: true,
      validationMessage: nil
    )
  }

  @Test func baseRefSelectedUpdatesSelectionAndClearsValidation() async {
    var state = makeState()
    state.validationMessage = "stale"
    let store = TestStore(initialState: state) {
      WorktreeCreationPromptFeature()
    }

    await store.send(.baseRefSelected("origin/feature")) {
      $0.selectedBaseRef = "origin/feature"
      $0.validationMessage = nil
    }
    await store.send(.baseRefSelected(nil)) {
      $0.selectedBaseRef = nil
    }
  }

  @Test func baseRefMenuLabelPrefersSelectionThenAuto() {
    #expect(makeState(selectedBaseRef: nil).baseRefMenuLabel == "origin/main")
    #expect(makeState(selectedBaseRef: "dev").baseRefMenuLabel == "dev")
    #expect(makeState(automaticBaseRef: "", selectedBaseRef: nil).baseRefMenuLabel == "Auto")
  }

  @Test func isSelectedBaseRefLocalClassifiesRemoteVsLocal() {
    // Auto resolves to the remote default -> not local.
    #expect(makeState(selectedBaseRef: nil).isSelectedBaseRefLocal == false)
    // A remote-tracking ref -> not local.
    #expect(makeState(selectedBaseRef: "origin/feature").isSelectedBaseRefLocal == false)
    // A local branch -> local.
    #expect(makeState(selectedBaseRef: "main").isSelectedBaseRefLocal == true)
    // Auto resolving to a local branch (no remotes) -> local.
    #expect(
      makeState(automaticBaseRef: "main", remoteNames: [], selectedBaseRef: nil)
        .isSelectedBaseRefLocal == true
    )
  }

  @Test func createButtonTappedThreadsSelectedBaseRef() async {
    let store = TestStore(initialState: makeState(selectedBaseRef: "origin/dev")) {
      WorktreeCreationPromptFeature()
    }

    await store.send(.set(\.branchName, "feature/new")) {
      $0.branchName = "feature/new"
    }
    await store.send(.createButtonTapped)
    await store.receive(
      .delegate(
        .submit(
          repositoryID: "/tmp/repo/",
          branchName: "feature/new",
          baseRef: "origin/dev",
          fetchOrigin: true
        )
      )
    )
  }

  @Test func createButtonTappedForcesFetchOffForLocalBaseRef() async {
    // fetchOrigin is true but the selected ref is local: submit must coerce it
    // off to match the disabled toggle (there is nothing to fetch).
    let store = TestStore(initialState: makeState(selectedBaseRef: "main")) {
      WorktreeCreationPromptFeature()
    }

    await store.send(.set(\.branchName, "feature/new")) {
      $0.branchName = "feature/new"
    }
    await store.send(.createButtonTapped)
    await store.receive(
      .delegate(
        .submit(
          repositoryID: "/tmp/repo/",
          branchName: "feature/new",
          baseRef: "main",
          fetchOrigin: false
        )
      )
    )
  }
}
