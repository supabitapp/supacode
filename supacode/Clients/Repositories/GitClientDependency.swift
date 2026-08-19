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
  /// One-shot `git --version` probe classifying an environment-level git
  /// failure (e.g. an unaccepted Xcode license). `nil` means git is usable.
  var checkGitEnvironment: @Sendable () async -> GitEnvironmentError?
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
  /// Resolves the layered `supaignore` filter (global, repo default worktree
  /// dir, per-repo committed) for a repo / base ref. Reports absence, effective
  /// patterns, or a read failure so the caller can fail safe instead of falling
  /// back to an unfiltered `wt` copy.
  var resolveSupaignore:
    @Sendable (
      _ repoRoot: URL,
      _ baseRef: String,
      _ globalFileURL: URL,
      _ repoDefaultFileURL: URL
    ) async -> SupaignoreResolution
  /// The ignored / untracked files that survive `supaignore` filtering.
  var worktreeCopyPlan:
    @Sendable (
      _ repoRoot: URL,
      _ copyIgnored: Bool,
      _ copyUntracked: Bool,
      _ excludePatterns: String
    ) async throws -> WorktreeCopyPlan
  /// Copies the surviving files into the new worktree (best-effort per entry).
  var copyWorktreeArtifacts:
    @Sendable (
      _ plan: WorktreeCopyPlan,
      _ from: URL,
      _ to: URL
    ) async -> WorktreeArtifactCopier.Outcome
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
  /// Uncommitted status of a worktree for the files inspector. `nil` on a probe
  /// failure (caller keeps its last-good snapshot); an empty snapshot is clean.
  var fileStatus: @Sendable (URL) async -> GitStatusSnapshot?
  var stageFile: @Sendable (_ path: String, _ root: URL) async throws -> Void
  var unstageFile: @Sendable (_ path: String, _ root: URL) async throws -> Void
  /// Discards a path's uncommitted changes: `git restore` for a tracked file,
  /// or moving an untracked file to the Trash (recoverable, never a hard
  /// delete). Only ever called for local worktrees, so the Trash path is safe.
  var discardFile: @Sendable (_ path: String, _ root: URL, _ tracked: Bool) async throws -> Void
  var remoteNames: @Sendable (_ repoRoot: URL) async throws -> [String]
  var fetchRemote: @Sendable (_ remote: String, _ repoRoot: URL) async throws -> Void
  var remoteInfo: @Sendable (_ repositoryRoot: URL) async -> GithubRemoteInfo?
  var setUpstreamBranch: @Sendable (_ branch: String, _ upstream: String, _ repoRoot: URL) async throws -> Void
  var unsetUpstreamBranch: @Sendable (_ branch: String, _ repoRoot: URL) async throws -> Void
  var upstreamBranchExists: @Sendable (_ ref: String, _ repoRoot: URL) async throws -> Bool
}

extension GitClientDependency: DependencyKey {
  static let liveValue = make(shell: .live)

  /// Remote flavor: every `git` / `wt` shell-out runs on `host` over SSH.
  /// `isGitRepository` / `rootDirectoryExists` still probe the *local*
  /// filesystem, which is unreachable for remote paths, so these stay local-only
  /// probes the remote load path never relies on.
  static func ssh(host: RemoteHost) -> GitClientDependency {
    var value = make(shell: .ssh(host: host))
    // Copying files into a new worktree is local-only: remote creations route
    // through `remoteCreateWorktree`, which never copies. Resolve to `.failed`
    // so the copy path can't fall back to an unfiltered copy if it is ever wired
    // for remote; the other supaignore closures then stay unreached.
    value.resolveSupaignore = { _, _, _, _ in
      .failed(reason: "Copying files into a worktree is not supported for remote repositories.")
    }
    return value
  }

  /// Reads a `supaignore` file. Only a genuinely not-found file is treated as
  /// absent (`nil`); any other failure (permissions, I/O) throws so resolution
  /// fails safe instead of misreading a hidden file as having no patterns.
  nonisolated private static func readSupaignoreFile(at url: URL) throws -> String? {
    do {
      return try String(contentsOf: url, encoding: .utf8)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return nil
    }
  }

  /// Reads all three layers and merges them, failing safe: any read / lookup
  /// error becomes `.failed` (copy nothing) rather than silently delegating to
  /// an unfiltered `wt` copy.
  nonisolated private static func resolveSupaignore(
    shell: ShellClient,
    repoRoot: URL,
    baseRef: String,
    globalFileURL: URL,
    repoDefaultFileURL: URL
  ) async -> SupaignoreResolution {
    do {
      let global = try readSupaignoreFile(at: globalFileURL)
      let repoDefault = try readSupaignoreFile(at: repoDefaultFileURL)
      let committed = try await GitClient(shell: shell).committedSupaignore(
        for: repoRoot, baseRef: baseRef)
      guard
        let merged = SupaignoreMerge.merged(
          global: global, repoDefault: repoDefault, committed: committed),
        let patterns = EffectiveSupaignorePatterns(merged)
      else {
        return .absent
      }
      return .resolved(patterns)
    } catch {
      SupaLogger("Git").error(
        "supaignore resolution failed for \(repoRoot.path(percentEncoded: false)): "
          + error.localizedDescription)
      return .failed(reason: error.localizedDescription)
    }
  }

  nonisolated private static func directoryExists(at url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(
      atPath: url.standardizedFileURL.path(percentEncoded: false), isDirectory: &isDirectory)
    return exists && isDirectory.boolValue
  }

  /// Runs the synchronous FileManager copy on its own task (as `discardFile`
  /// does) so the awaiting caller's thread is freed while a large filtered set
  /// copies.
  nonisolated private static func copyArtifacts(
    _ plan: WorktreeCopyPlan, from source: URL, to destination: URL
  ) async -> WorktreeArtifactCopier.Outcome {
    await Task.detached(priority: .userInitiated) {
      WorktreeArtifactCopier.copy(
        relativePaths: plan.ignored + plan.untracked, from: source, to: destination)
    }.value
  }

  /// Discards a path's uncommitted changes: `git restore` for a tracked file, or
  /// unstage then move an untracked file to the Trash (recoverable).
  nonisolated private static func discardFile(
    shell: ShellClient, path: String, root: URL, tracked: Bool
  ) async throws {
    guard tracked else {
      try await GitClient(shell: shell).unstageFile(path, in: root)
      let url = root.appending(path: path)
      try await Task.detached(priority: .userInitiated) {
        // A staged addition can already be gone from the worktree (`AD`); unstaging
        // alone then cleans it, so only trash a file still present.
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
      }.value
      return
    }
    try await GitClient(shell: shell).discardTrackedFile(path, in: root)
  }

  /// Single source of truth for the dependency's closures, parameterized on the
  /// transport so the local and SSH flavors can't drift.
  private static func make(shell: ShellClient) -> GitClientDependency {
    GitClientDependency(
      repoRoot: { try await GitClient(shell: shell).repoRoot(for: $0) },
      isGitRepository: { Repository.isGitRepository(at: $0) },
      rootDirectoryExists: { Self.directoryExists(at: $0) },
      checkGitEnvironment: { await GitClient(shell: shell).gitEnvironmentError() },
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
      resolveSupaignore: { repoRoot, baseRef, globalFileURL, repoDefaultFileURL in
        await Self.resolveSupaignore(
          shell: shell,
          repoRoot: repoRoot,
          baseRef: baseRef,
          globalFileURL: globalFileURL,
          repoDefaultFileURL: repoDefaultFileURL
        )
      },
      worktreeCopyPlan: { repoRoot, copyIgnored, copyUntracked, excludePatterns in
        try await GitClient(shell: shell).worktreeCopyPlan(
          for: repoRoot,
          copyIgnored: copyIgnored,
          copyUntracked: copyUntracked,
          excludePatterns: excludePatterns
        )
      },
      copyWorktreeArtifacts: { plan, source, destination in
        await Self.copyArtifacts(plan, from: source, to: destination)
      },
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
      fileStatus: { await GitClient(shell: shell).fileStatus(at: $0) },
      stageFile: { path, root in try await GitClient(shell: shell).stageFile(path, in: root) },
      unstageFile: { path, root in try await GitClient(shell: shell).unstageFile(path, in: root) },
      discardFile: { path, root, tracked in
        try await Self.discardFile(shell: shell, path: path, root: root, tracked: tracked)
      },
      remoteNames: { try await GitClient(shell: shell).remoteNames(for: $0) },
      fetchRemote: { remote, repoRoot in try await GitClient(shell: shell).fetchRemote(remote, for: repoRoot) },
      remoteInfo: { repositoryRoot in
        await GitClient(shell: shell).remoteInfo(for: repositoryRoot)
      },
      setUpstreamBranch: { branch, upstream, repoRoot in
        try await GitClient(shell: shell).setUpstreamBranch(branch, to: upstream, for: repoRoot)
      },
      unsetUpstreamBranch: { branch, repoRoot in
        try await GitClient(shell: shell).unsetUpstreamBranch(branch, for: repoRoot)
      },
      upstreamBranchExists: { ref, repoRoot in
        try await GitClient(shell: shell).upstreamBranchExists(ref, for: repoRoot)
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
    // Default to a healthy git environment so tests don't shell out to real
    // `git --version`; the license-gate tests override this explicitly.
    value.checkGitEnvironment = { nil }
    value.reconcileSupacodeLocks = { _ in }
    // Default to "no supaignore" so unstubbed creation tests keep the
    // unfiltered `wt` copy path and never shell out; filter tests override it.
    value.resolveSupaignore = { _, _, _, _ in .absent }
    // No git status probe by default: fixtures with fake `/tmp/...` paths get a
    // no-op (nil) so the reducer never decorates. Status tests override this.
    value.fileStatus = { _ in nil }
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
