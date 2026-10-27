import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Sharing
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct RepositoriesFeatureBranchReuseTests {
  private let repoURL = URL(fileURLWithPath: "/tmp/reuse-repo")
  private var repoID: Repository.ID { RepositoryID(repoURL.path(percentEncoded: false)) }

  private func makeState() -> RepositoriesFeature.State {
    let mainWorktree = Worktree(
      id: WorktreeID(repoURL.path(percentEncoded: false)),
      name: "main",
      detail: "",
      workingDirectory: repoURL,
      repositoryRootURL: repoURL
    )
    var state = RepositoriesFeature.State()
    state.repositories = [
      Repository(id: repoID, rootURL: repoURL, name: "reuse-repo", worktrees: [mainWorktree])
    ]
    state.repositoryRoots = [repoURL]
    return state
  }

  @Test(.dependencies) func reuseChecksOutTheBranchWithoutBaseFetchOrUpstream() async {
    struct StreamCall: Equatable {
      let baseRef: String
      let directoryOverride: URL?
    }
    let streamCall = LockIsolated<StreamCall?>(nil)
    let touchedBaseOrTracking = LockIsolated<[String]>([])
    let created = Worktree(
      id: WorktreeID("/tmp/reuse-base/feature-x"),
      name: "feature-x",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/reuse-base/feature-x"),
      repositoryRootURL: repoURL
    )
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.defaultWorktreeBaseDirectoryPath = "/tmp/reuse-base" }
    let store = TestStore(initialState: makeState()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.gitClient.localBranchNames = { _ in ["main", "feature-x"] }
      $0.gitClient.branchAvailability = { _, _ in .reusable }
      $0.gitClient.isValidBranchName = { _, _ in true }
      $0.gitClient.isBareRepository = { _ in false }
      $0.gitClient.automaticWorktreeBaseRef = { _ in "origin/main" }
      $0.gitClient.ignoredFileCount = { _ in 0 }
      $0.gitClient.untrackedFileCount = { _ in 0 }
      $0.gitClient.remoteNames = { _ in
        touchedBaseOrTracking.withValue { $0.append("remoteNames") }
        return ["origin"]
      }
      $0.gitClient.fetchRemote = { _, _ in touchedBaseOrTracking.withValue { $0.append("fetch") } }
      $0.gitClient.upstreamBranchExists = { _, _ in
        touchedBaseOrTracking.withValue { $0.append("upstreamCheck") }
        return true
      }
      $0.gitClient.setUpstreamBranch = { _, _, _ in touchedBaseOrTracking.withValue { $0.append("setUpstream") } }
      $0.gitClient.createWorktreeStream = { _, _, _, _, _, baseRef, directoryOverride in
        streamCall.setValue(StreamCall(baseRef: baseRef, directoryOverride: directoryOverride))
        return AsyncThrowingStream { continuation in
          continuation.yield(.finished(created))
          continuation.finish()
        }
      }
      $0.gitClient.worktrees = { _ in [created] }
    }
    store.exhaustivity = .off

    await store.send(
      .createWorktreeInRepository(
        repositoryID: repoID,
        nameSource: .explicit("feature-x"),
        baseRefSource: .explicit("origin/main"),
        upstream: .branch("origin/feature-x"),
        fetchOrigin: true,
        reuseExistingBranch: true
      )
    )
    await store.receive(\.createRandomWorktreeSucceeded)
    await store.finish()

    // `wt sw` adopts a branch without a worktree only given `--path`, and `--from` would be ignored.
    let expectedDirectory = SupacodePaths.previewWorktreeDirectory(
      defaultBaseDirectory: SupacodePaths.worktreeBaseDirectory(
        for: repoURL, globalDefaultPath: "/tmp/reuse-base", repositoryOverridePath: nil),
      repositoryRootURL: repoURL,
      nameOverride: nil,
      pathOverride: nil,
      branchName: "feature-x"
    )
    #expect(streamCall.value == StreamCall(baseRef: "", directoryOverride: expectedDirectory))
    #expect(touchedBaseOrTracking.value.isEmpty)
  }

  @Test(.dependencies) func reuseStopsWhenTheBranchVanishesBeforeWt() async {
    // Someone deletes the branch right after the first check, so the re-check finds it gone.
    let branchDeleted = LockIsolated(false)
    let streamStarted = LockIsolated(false)
    let store = TestStore(initialState: makeState()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.gitClient.localBranchNames = { _ in branchDeleted.value ? ["main"] : ["main", "feature-x"] }
      $0.gitClient.branchAvailability = { _, _ in
        defer { branchDeleted.setValue(true) }
        return branchDeleted.value ? .absent : .reusable
      }
      $0.gitClient.isValidBranchName = { _, _ in true }
      $0.gitClient.isBareRepository = { _ in false }
      $0.gitClient.ignoredFileCount = { _ in 0 }
      $0.gitClient.untrackedFileCount = { _ in 0 }
      $0.gitClient.createWorktreeStream = { _, _, _, _, _, _, _ in
        streamStarted.setValue(true)
        return AsyncThrowingStream { $0.finish() }
      }
    }
    store.exhaustivity = .off

    await store.send(
      .createWorktreeInRepository(
        repositoryID: repoID,
        nameSource: .explicit("feature-x"),
        baseRefSource: .explicit("origin/main"),
        fetchOrigin: false,
        reuseExistingBranch: true
      )
    )
    await store.receive(\.createRandomWorktreeFailed)
    await store.finish()

    // Without the stop, `wt` would make a new `feature-x` from HEAD, since the base ref was skipped.
    #expect(!streamStarted.value)
    #expect(store.state.alert?.title == TextState("Branch changed during creation"))
  }
}
