import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import supacode

@MainActor
struct RepositoriesFeaturePersistenceTests {
  @Test(.dependencies) func taskLoadsPinnedWorktreesBeforeRepositories() async {
    let pinned = ["/tmp/repo/wt-1"]
    let repositoryOrder = ["/tmp/repo"]
    let worktreeOrder = ["/tmp/repo": ["/tmp/repo/wt-1"]]
    let calls = LockIsolated<[String]>([])
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence = RepositoryPersistenceClient(
        loadRoots: {
          calls.withValue { $0.append("loadRoots") }
          return []
        },
        saveRoots: { _ in },
        loadPinnedWorktreeIDs: {
          calls.withValue { $0.append("loadPinnedWorktreeIDs") }
          return pinned
        },
        savePinnedWorktreeIDs: { _ in },
        loadArchivedWorktreeDates: {
          calls.withValue { $0.append("loadArchivedWorktreeDates") }
          return [:]
        },
        saveArchivedWorktreeDates: { _ in },
        loadRepositoryOrderIDs: {
          calls.withValue { $0.append("loadRepositoryOrderIDs") }
          return repositoryOrder
        },
        saveRepositoryOrderIDs: { _ in },
        loadWorktreeOrderByRepository: {
          calls.withValue { $0.append("loadWorktreeOrderByRepository") }
          return worktreeOrder
        },
        saveWorktreeOrderByRepository: { _ in },
        loadLastFocusedWorktreeID: {
          calls.withValue { $0.append("loadLastFocusedWorktreeID") }
          return nil
        },
        saveLastFocusedWorktreeID: { _ in }
      )
    }

    store.exhaustivity = .off
    await store.send(.task)
    await store.finish()
    #expect(
      calls.value == [
        "loadPinnedWorktreeIDs",
        "loadArchivedWorktreeDates",
        "loadLastFocusedWorktreeID",
        "loadRepositoryOrderIDs",
        "loadWorktreeOrderByRepository",
        "loadRoots",
      ])
  }
}
