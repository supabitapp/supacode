import ComposableArchitecture
import Foundation
import Sharing
import SupacodeSettingsShared

/// Root-path persistence for the local repository list. All other
/// sidebar slices (pin / collapse / repo order / worktree order /
/// focus / archive) moved to `@Shared(.sidebar)` + the
/// `SidebarPersistenceMigrator` — this client now only owns
/// `repositoryRoots`.
struct RepositoryPersistenceClient {
  var loadRoots: @Sendable () async -> [String]
  var saveRoots: @Sendable ([String]) async -> Void
}

extension RepositoryPersistenceClient: DependencyKey {
  static let liveValue: RepositoryPersistenceClient = {
    RepositoryPersistenceClient(
      loadRoots: {
        @Shared(.repositoryRoots) var roots: [String]
        return roots
      },
      saveRoots: { roots in
        @Shared(.repositoryRoots) var sharedRoots: [String]
        $sharedRoots.withLock {
          $0 = roots
        }
      }
    )
  }()
  static let testValue = RepositoryPersistenceClient(
    loadRoots: { [] },
    saveRoots: { _ in }
  )
}

extension DependencyValues {
  var repositoryPersistence: RepositoryPersistenceClient {
    get { self[RepositoryPersistenceClient.self] }
    set { self[RepositoryPersistenceClient.self] = newValue }
  }
}
