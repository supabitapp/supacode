import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

struct GitClientDependency: Sendable {
  var repoRoot: @Sendable (URL) async throws -> URL
  var isGitRepository: @Sendable (URL) async -> Bool
  /// Whether a root URL still points at a readable directory on
  /// disk. Separate from `isGitRepository` because a folder-kind
  /// root can exist without being a git repository, and we need
  /// to distinguish "directory is gone" (surface a load failure)
  /// from "directory exists but isn't git" (classify as folder).
  /// Defaults to `true` in `testValue` so fixtures with fake
  /// `/tmp/...` paths keep working; tests that exercise the
  /// missing-directory path override explicitly.
  var rootDirectoryExists: @Sendable (URL) async -> Bool
  var worktrees: @Sendable (URL) async throws -> [Worktree]
  var reconcileSupacodeLocks: @Sendable (URL) async -> Void
  var localBranchNames: @Sendable (URL) async throws -> Set<String>
  var renameBranch: @Sendable (_ oldName: String, _ newName: String, _ repoRoot: URL) async throws -> Void
  var isValidBranchName: @Sendable (String, URL) async -> Bool
  var branchInventory: @Sendable (URL, [String]) async throws -> GitBranchInventory
  var defaultRemoteBranchRef: @Sendable (URL) async throws -> String?
  var automaticWorktreeBaseRef: @Sendable (URL) async -> String?
  var ignoredFileCount: @Sendable (URL) async throws -> Int
  var untrackedFileCount: @Sendable (URL) async throws -> Int
  var createWorktree:
    @Sendable (
      _ name: String,
      _ repoRoot: URL,
      _ baseDirectory: URL,
      _ copyIgnored: Bool,
      _ copyUntracked: Bool,
      _ baseRef: String
    ) async throws
      -> Worktree
  var createWorktreeStream:
    @Sendable (
      _ name: String,
      _ repoRoot: URL,
      _ baseDirectory: URL,
      _ copyIgnored: Bool,
      _ copyUntracked: Bool,
      _ baseRef: String,
      _ directoryOverride: URL?
    ) -> AsyncThrowingStream<GitWorktreeCreateEvent, Error>
  var cloneStream:
    @Sendable (
      _ repositoryURL: String,
      _ destination: URL,
      _ branch: String?,
      _ depth: Int?
    ) -> AsyncThrowingStream<GitCloneEvent, Error>
  var removeWorktree: @Sendable (_ worktree: Worktree, _ deleteBranch: Bool) async throws -> URL
  var isBareRepository: @Sendable (_ repoRoot: URL) async throws -> Bool
  var branchName: @Sendable (URL) async -> String?
  var lineChanges: @Sendable (URL) async -> (added: Int, removed: Int)?
  var remoteNames: @Sendable (_ repoRoot: URL) async throws -> [String]
  var fetchRemote: @Sendable (_ remote: String, _ repoRoot: URL) async throws -> Void
  var remoteInfo: @Sendable (_ repositoryRoot: URL) async -> GithubRemoteInfo?
}

extension GitClientDependency: DependencyKey {
  static let liveValue = make(shell: .live)

  /// Remote flavor: every `git` / `wt` shell-out runs on `host` over SSH.
  /// `isGitRepository` / `rootDirectoryExists` still probe the *local*
  /// filesystem, which is unreachable for remote paths, so these stay local-only
  /// probes the remote load path never relies on.
  static func ssh(host: RemoteHost) -> GitClientDependency {
    make(shell: .ssh(host: host))
  }

  /// Single source of truth for the dependency's closures, parameterized on the
  /// transport so the local and SSH flavors can't drift.
  private static func make(shell: ShellClient) -> GitClientDependency {
    GitClientDependency(
      repoRoot: { try await GitClient(shell: shell).repoRoot(for: $0) },
      isGitRepository: { Repository.isGitRepository(at: $0) },
      rootDirectoryExists: { url in
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
          atPath: url.standardizedFileURL.path(percentEncoded: false),
          isDirectory: &isDirectory
        )
        return exists && isDirectory.boolValue
      },
      worktrees: { try await GitClient(shell: shell).worktrees(for: $0) },
      reconcileSupacodeLocks: { await GitClient(shell: shell).reconcileSupacodeLocks(for: $0) },
      localBranchNames: { try await GitClient(shell: shell).localBranchNames(for: $0) },
      renameBranch: { oldName, newName, repoRoot in
        try await GitClient(shell: shell).renameBranch(from: oldName, to: newName, for: repoRoot)
      },
      isValidBranchName: { branchName, repoRoot in
        await GitClient(shell: shell).isValidBranchName(branchName, for: repoRoot)
      },
      branchInventory: { try await GitClient(shell: shell).branchInventory(for: $0, remoteNames: $1) },
      defaultRemoteBranchRef: { try await GitClient(shell: shell).defaultRemoteBranchRef(for: $0) },
      automaticWorktreeBaseRef: { await GitClient(shell: shell).automaticWorktreeBaseRef(for: $0) },
      ignoredFileCount: { try await GitClient(shell: shell).ignoredFileCount(for: $0) },
      untrackedFileCount: { try await GitClient(shell: shell).untrackedFileCount(for: $0) },
      createWorktree: { name, repoRoot, baseDirectory, copyIgnored, copyUntracked, baseRef in
        try await GitClient(shell: shell).createWorktree(
          named: name,
          in: repoRoot,
          baseDirectory: baseDirectory,
          copyFiles: (ignored: copyIgnored, untracked: copyUntracked),
          baseRef: baseRef
        )
      },
      createWorktreeStream: { name, repoRoot, baseDirectory, copyIgnored, copyUntracked, baseRef, directoryOverride in
        GitClient(shell: shell).createWorktreeStream(
          named: name,
          in: repoRoot,
          baseDirectory: baseDirectory,
          copyFiles: (ignored: copyIgnored, untracked: copyUntracked),
          baseRef: baseRef,
          directoryOverride: directoryOverride
        )
      },
      cloneStream: { repositoryURL, destination, branch, depth in
        GitClient(shell: shell).cloneStream(
          repositoryURL: repositoryURL,
          into: destination,
          branch: branch,
          depth: depth
        )
      },
      removeWorktree: { worktree, deleteBranch in
        try await GitClient(shell: shell).removeWorktree(worktree, deleteBranch: deleteBranch)
      },
      isBareRepository: { repoRoot in
        try await GitClient(shell: shell).isBareRepository(for: repoRoot)
      },
      branchName: { await GitClient(shell: shell).symbolicHeadBranch(at: $0) },
      lineChanges: { await GitClient(shell: shell).lineChanges(at: $0) },
      remoteNames: { try await GitClient(shell: shell).remoteNames(for: $0) },
      fetchRemote: { remote, repoRoot in try await GitClient(shell: shell).fetchRemote(remote, for: repoRoot) },
      remoteInfo: { repositoryRoot in
        await GitClient(shell: shell).remoteInfo(for: repositoryRoot)
      }
    )
  }
  // Tests default to "git repository" classification so existing
  // fixtures that mock `gitClient.worktrees` without creating real
  // `.git` directories on disk keep exercising the git code path.
  // Folder-kind tests override this closure explicitly.
  static var testValue: GitClientDependency {
    var value = liveValue
    value.isGitRepository = { _ in true }
    value.rootDirectoryExists = { _ in true }
    value.reconcileSupacodeLocks = { _ in }
    // `liveValue` shells out to real `git clone`; a no-op default keeps an
    // unstubbed test from cloning over the network. Clone tests override this.
    value.cloneStream = { _, _, _, _ in
      AsyncThrowingStream { $0.finish() }
    }
    return value
  }
}

extension DependencyValues {
  var gitClient: GitClientDependency {
    get { self[GitClientDependency.self] }
    set { self[GitClientDependency.self] = newValue }
  }
}
