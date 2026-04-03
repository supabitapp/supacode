import ComposableArchitecture
import Foundation
import Testing

@testable import supacode

@MainActor
@Suite(.serialized)
struct DeeplinkInputConfirmationFeatureTests {
  @Test func runTappedDelegatesConfirmWithAlwaysAllowFalse() async {
    let state = DeeplinkInputConfirmationFeature.State(
      worktreeID: "/tmp/wt",
      worktreeName: "wt",
      repositoryName: "repo",
      message: .command("echo hello"),
      action: .tabNew(input: "echo hello", id: nil),
    )
    let store = TestStore(initialState: state) {
      DeeplinkInputConfirmationFeature()
    }

    await store.send(.runTapped)
    await store.receive(
      .delegate(.confirm(worktreeID: "/tmp/wt", action: .tabNew(input: "echo hello", id: nil), alwaysAllow: false)))
  }

  @Test func runTappedDelegatesConfirmWithAlwaysAllowTrue() async {
    var state = DeeplinkInputConfirmationFeature.State(
      worktreeID: "/tmp/wt",
      worktreeName: "wt",
      repositoryName: "repo",
      message: .command("echo hello"),
      action: .tabNew(input: "echo hello", id: nil),
    )
    state.alwaysAllow = true
    let store = TestStore(initialState: state) {
      DeeplinkInputConfirmationFeature()
    }

    await store.send(.runTapped)
    await store.receive(
      .delegate(.confirm(worktreeID: "/tmp/wt", action: .tabNew(input: "echo hello", id: nil), alwaysAllow: true)))
  }

  @Test func cancelTappedDelegatesCancel() async {
    let state = DeeplinkInputConfirmationFeature.State(
      worktreeID: "/tmp/wt",
      worktreeName: "wt",
      repositoryName: nil,
      message: .command("rm -rf /"),
      action: .tabNew(input: "rm -rf /", id: nil),
    )
    let store = TestStore(initialState: state) {
      DeeplinkInputConfirmationFeature()
    }

    await store.send(.cancelTapped)
    await store.receive(.delegate(.cancel))
  }

  @Test func alwaysAllowBindingUpdatesState() async {
    let state = DeeplinkInputConfirmationFeature.State(
      worktreeID: "/tmp/wt",
      worktreeName: "wt",
      repositoryName: "repo",
      message: .command("echo hello"),
      action: .tabNew(input: "echo hello", id: nil),
    )
    let store = TestStore(initialState: state) {
      DeeplinkInputConfirmationFeature()
    }

    await store.send(.binding(.set(\.alwaysAllow, true))) {
      $0.alwaysAllow = true
    }
  }
}
