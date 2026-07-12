import Foundation

@testable import SupacodeSettingsShared
@testable import supacode

/// Test-only convenience mirroring the dissolved `RemoteRepositoryConfig`: a
/// remote host + path with the derived helpers the old type exposed. Production
/// stores remotes as self-descriptive id strings in `remoteRepositoryRoots`.
struct TestRemoteRepo {
  var host: RemoteHost
  var remotePath: String

  init(host: RemoteHost, remotePath: String, displayName: String = "") {
    self.host = host
    self.remotePath = remotePath
  }

  var normalizedRemotePath: String { RepositoryLocation.normalizedRemotePath(remotePath) }
  var resolvedDisplayName: String { RepositoriesFeature.remoteRepositoryName(host: host, remotePath: remotePath) }
  var id: Repository.ID { RepositoriesFeature.remoteRepositoryID(host: host, remotePath: remotePath) }
}

extension RepositoriesFeature {
  static func remoteRepositoryID(for config: TestRemoteRepo) -> Repository.ID {
    remoteRepositoryID(host: config.host, remotePath: config.remotePath)
  }

  static func remoteMainWorktree(config: TestRemoteRepo) -> Worktree {
    remoteMainWorktree(host: config.host, remotePath: config.remotePath)
  }

  static func remoteFolderRepository(config: TestRemoteRepo, repoID: Repository.ID) -> Repository {
    remoteFolderRepository(host: config.host, remotePath: config.remotePath, repoID: repoID)
  }

  static func remotePlaceholderRepository(config: TestRemoteRepo, repoID: Repository.ID) -> Repository {
    remotePlaceholderRepository(host: config.host, remotePath: config.remotePath, repoID: repoID)
  }

  static func loadRemoteRepository(
    _ config: TestRemoteRepo,
    repoID: Repository.ID,
    shell: ShellClient? = nil
  ) async -> (repository: Repository, failure: LoadFailure?) {
    await loadRemoteRepository(host: config.host, remotePath: config.remotePath, repoID: repoID, shell: shell)
  }
}
