import ComposableArchitecture
import Foundation
import Testing

@testable import supacode

@MainActor
@Suite(.serialized)
struct RenameBranchFeatureTests {
  private let repoRoot = URL(fileURLWithPath: "/tmp/rename-repo")

  private func makeState(
    newName: String? = nil,
    currentName: String = "feature/old"
  ) -> RenameBranchFeature.State {
    var state = RenameBranchFeature.State(
      worktreeID: "/tmp/rename-repo/feature-old",
      repositoryID: "/tmp/rename-repo",
      repositoryRootURL: repoRoot,
      host: nil,
      currentName: currentName
    )
    if let newName {
      state.newName = newName
    }
    return state
  }

  @Test func cancelDelegatesCancel() async {
    let store = TestStore(initialState: makeState()) {
      RenameBranchFeature()
    }
    await store.send(.cancelButtonTapped)
    await store.receive(.delegate(.cancel))
  }

  @Test func unchangedNameDoesNotSubmit() async {
    let store = TestStore(initialState: makeState()) {
      RenameBranchFeature()
    }
    #expect(store.state.canSubmit == false)
    await store.send(.renameButtonTapped)
  }

  @Test func emptyNameDoesNotSubmit() async {
    let store = TestStore(initialState: makeState(newName: "   ")) {
      RenameBranchFeature()
    } withDependencies: {
      $0.gitClient.isValidBranchName = { _, _ in false }
    }
    #expect(store.state.canSubmit == false)
    await store.send(.renameButtonTapped)
  }

  @Test func invalidBranchNameSurfacesValidationMessage() async {
    let store = TestStore(initialState: makeState(newName: "bad name")) {
      RenameBranchFeature()
    } withDependencies: {
      $0.gitClient.isValidBranchName = { _, _ in false }
      $0.gitClient.localBranchNames = { _ in [] }
      $0.gitClient.renameBranch = { _, _, _ in
        Issue.record("renameBranch must not be called for invalid names")
      }
    }
    await store.send(.renameButtonTapped) {
      $0.isSubmitting = true
    }
    await store.receive(.renameFailed("Enter a valid git branch name and try again.")) {
      $0.isSubmitting = false
      $0.validationMessage = "Enter a valid git branch name and try again."
    }
  }

  @Test func existingBranchSurfacesCollisionMessage() async {
    let store = TestStore(initialState: makeState(newName: "feature/new")) {
      RenameBranchFeature()
    } withDependencies: {
      $0.gitClient.isValidBranchName = { _, _ in true }
      $0.gitClient.localBranchNames = { _ in ["feature/new"] }
      $0.gitClient.renameBranch = { _, _, _ in
        Issue.record("renameBranch must not be called when target already exists")
      }
    }
    await store.send(.renameButtonTapped) {
      $0.isSubmitting = true
    }
    await store.receive(.renameFailed("A branch named 'feature/new' already exists.")) {
      $0.isSubmitting = false
      $0.validationMessage = "A branch named 'feature/new' already exists."
    }
  }

  private struct RenameCall: Equatable {
    let oldName: String
    let newName: String
    let repoRoot: URL
  }

  @Test func successfulRenameDelegatesRenamed() async {
    let renameCalls = LockIsolated<[RenameCall]>([])
    let store = TestStore(initialState: makeState(newName: "  feature/new  ")) {
      RenameBranchFeature()
    } withDependencies: {
      $0.gitClient.isValidBranchName = { _, _ in true }
      $0.gitClient.localBranchNames = { _ in [] }
      $0.gitClient.renameBranch = { oldName, newName, root in
        renameCalls.withValue {
          $0.append(RenameCall(oldName: oldName, newName: newName, repoRoot: root))
        }
      }
    }
    await store.send(.renameButtonTapped) {
      $0.isSubmitting = true
    }
    await store.receive(
      .delegate(
        .renamed(
          worktreeID: "/tmp/rename-repo/feature-old",
          repositoryID: "/tmp/rename-repo",
          newName: "feature/new"
        )
      )
    )
    #expect(
      renameCalls.value == [
        RenameCall(oldName: "feature/old", newName: "feature/new", repoRoot: repoRoot)
      ]
    )
  }

  @Test func gitFailureSurfacesMessage() async {
    let store = TestStore(initialState: makeState(newName: "feature/new")) {
      RenameBranchFeature()
    } withDependencies: {
      $0.gitClient.isValidBranchName = { _, _ in true }
      $0.gitClient.localBranchNames = { _ in [] }
      $0.gitClient.renameBranch = { _, _, _ in
        throw GitClientError.commandFailed(command: "git -C /Users/me/repo branch -m old new", message: "boom")
      }
    }
    await store.send(.renameButtonTapped) {
      $0.isSubmitting = true
    }
    await store.receive(.renameFailed("boom")) {
      $0.isSubmitting = false
      $0.validationMessage = "boom"
    }
  }

  @Test func bindingNewNameClearsValidationMessage() async {
    var initial = makeState(newName: "feature/new")
    initial.validationMessage = "stale"
    let store = TestStore(initialState: initial) {
      RenameBranchFeature()
    }
    await store.send(.binding(.set(\.newName, "feature/newer"))) {
      $0.newName = "feature/newer"
      $0.validationMessage = nil
    }
  }

  // The inverted second clause in the collision check lets a case-only rename
  // (`feature/old` -> `Feature/Old`) reach `git branch -m`, where the mounted
  // volume's case sensitivity decides whether the rename succeeds or fails.
  @Test func caseOnlyRenameClearsPreCheckAndCallsGit() async {
    let renameCalls = LockIsolated<[RenameCall]>([])
    let store = TestStore(initialState: makeState(newName: "Feature/Old")) {
      RenameBranchFeature()
    } withDependencies: {
      $0.gitClient.isValidBranchName = { _, _ in true }
      $0.gitClient.localBranchNames = { _ in ["feature/old"] }
      $0.gitClient.renameBranch = { oldName, newName, root in
        renameCalls.withValue {
          $0.append(RenameCall(oldName: oldName, newName: newName, repoRoot: root))
        }
      }
    }
    await store.send(.renameButtonTapped) {
      $0.isSubmitting = true
    }
    await store.receive(
      .delegate(
        .renamed(
          worktreeID: "/tmp/rename-repo/feature-old",
          repositoryID: "/tmp/rename-repo",
          newName: "Feature/Old"
        )
      )
    )
    #expect(
      renameCalls.value == [
        RenameCall(oldName: "feature/old", newName: "Feature/Old", repoRoot: repoRoot)
      ]
    )
  }

  @Test func friendlyErrorMaps_alreadyExists() {
    let err = GitClientError.commandFailed(
      command: "git branch -m",
      message: "fatal: A branch named 'main' already exists."
    )
    #expect(
      RenameBranchFeature.friendlyRenameError(from: err, target: "main")
        == "A branch named 'main' already exists."
    )
  }

  @Test func friendlyErrorMaps_checkedOutElsewhere() {
    let err = GitClientError.commandFailed(
      command: "git branch -m",
      message: "fatal: Branches cannot be renamed: 'feature' is checked out at '/path/wt'."
    )
    let mapped = RenameBranchFeature.friendlyRenameError(from: err, target: "feature")
    #expect(mapped.contains("checked out in another worktree"))
  }

  @Test func friendlyErrorMaps_invalidRefname() {
    let err = GitClientError.commandFailed(
      command: "git branch -m",
      message: "fatal: 'bad name' is not a valid branch name."
    )
    let mapped = RenameBranchFeature.friendlyRenameError(from: err, target: "bad name")
    #expect(mapped == "Git rejected 'bad name' as an invalid branch name.")
  }

  @Test func friendlyErrorMaps_fallbackReturnsTrimmedMessage() {
    let err = GitClientError.commandFailed(
      command: "git -C /private/var/users/me/repo branch -m old new",
      message: "weird new failure"
    )
    let mapped = RenameBranchFeature.friendlyRenameError(from: err, target: "x")
    #expect(mapped == "weird new failure")
    #expect(mapped.contains("branch -m") == false)
    #expect(mapped.contains("/private/var/users/me/repo") == false)
  }

  @Test func friendlyErrorMaps_fallbackHandlesEmptyMessage() {
    let err = GitClientError.commandFailed(command: "git branch -m", message: "")
    let mapped = RenameBranchFeature.friendlyRenameError(from: err, target: "x")
    #expect(mapped == "git rejected the rename.")
  }
}
