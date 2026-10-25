import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Sharing
import SupacodeSettingsShared
import Testing

@testable import supacode

/// End to end against real git, the bundled `wt`, and the real filesystem: a failed creation
/// must never destroy data it didn't create (#878).
@MainActor
struct RepositoriesFeatureCreationDataLossTests {
  private struct Sandbox {
    let root: URL
    let repoURL: URL
    let baseDirectory: URL

    init() async throws {
      root = URL(filePath: "/tmp", directoryHint: .isDirectory)
        .appending(path: "gh878-e2e-\(UUID().uuidString)", directoryHint: .isDirectory)
      repoURL = root.appending(path: "repo", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
      let repoPath = repoURL.path(percentEncoded: false)
      try await Self.git(["init", "-b", "main", repoPath])
      try await Self.git(["-C", repoPath, "config", "user.email", "test@example.com"])
      try await Self.git(["-C", repoPath, "config", "user.name", "Test User"])
      try await Self.git(["-C", repoPath, "commit", "--allow-empty", "-m", "init"])
      baseDirectory = SupacodePaths.worktreeBaseDirectory(
        for: repoURL,
        globalDefaultPath: root.appending(path: "base").path(percentEncoded: false),
        repositoryOverridePath: nil
      )
    }

    func cleanup() {
      try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    static func git(_ arguments: [String]) async throws -> String {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
      process.arguments = arguments
      process.environment = ProcessInfo.processInfo.environment.merging([
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_SYSTEM": "/dev/null",
      ]) { _, override in override }
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = pipe
      try await process.runToExit()
      let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      guard process.terminationStatus == 0 else {
        throw GitClientError.commandFailed(command: "git \(arguments.joined(separator: " "))", message: output)
      }
      return output
    }
  }

  private func makeStore(sandbox: Sandbox, worktrees: [Worktree]) -> TestStoreOf<RepositoriesFeature> {
    let repository = Repository(
      id: RepositoryID(sandbox.repoURL.path(percentEncoded: false)),
      rootURL: sandbox.repoURL,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: worktrees)
    )
    var state = RepositoriesFeature.State()
    state.repositories = IdentifiedArray(uniqueElements: [repository])
    state.repositoryRoots = [repository.rootURL]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.gitClient = .liveValue
    }
    store.exhaustivity = .off
    return store
  }

  private func makeWorktree(at url: URL, branch: String, sandbox: Sandbox) -> Worktree {
    Worktree(
      location: .local(workingDirectory: url, repositoryRoot: sandbox.repoURL),
      kind: .git,
      name: branch,
      detail: "",
      createdAt: nil
    )
  }

  @Test(.dependencies) func branchPrefixFailureKeepsNestedWorktrees() async throws {
    let sandbox = try await Sandbox()
    defer { sandbox.cleanup() }
    useSandboxBase(sandbox)
    let nestedURL = sandbox.baseDirectory.appending(path: "experiments/a", directoryHint: .isDirectory)
    try await Sandbox.git([
      "-C", sandbox.repoURL.path(percentEncoded: false), "worktree", "add", "-b", "experiments/a",
      nestedURL.path(percentEncoded: false),
    ])
    let uncommitted = nestedURL.appending(path: "uncommitted.txt")
    try "precious".write(to: uncommitted, atomically: true, encoding: .utf8)
    let store = makeStore(
      sandbox: sandbox,
      worktrees: [
        makeWorktree(at: sandbox.repoURL, branch: "main", sandbox: sandbox),
        makeWorktree(at: nestedURL, branch: "experiments/a", sandbox: sandbox),
      ]
    )

    await store.send(
      .createWorktreeInRepository(
        repositoryID: RepositoryID(sandbox.repoURL.path(percentEncoded: false)),
        nameSource: .explicit("experiments"),
        baseRefSource: .repositorySetting,
        fetchOrigin: false
      )
    )
    await store.receive(\.createRandomWorktreeFailed, timeout: .seconds(60))
    await store.finish(timeout: .seconds(60))

    #expect(FileManager.default.fileExists(atPath: uncommitted.path(percentEncoded: false)))
  }

  @Test(.dependencies) func failureWithPathOverrideKeepsUnrelatedFolderAtDefaultPath() async throws {
    let sandbox = try await Sandbox()
    defer { sandbox.cleanup() }
    useSandboxBase(sandbox)
    // An unrelated folder sits where the default placement would go; the creation targets elsewhere.
    let unrelated = sandbox.baseDirectory.appending(path: "feature", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
    let keep = unrelated.appending(path: "keep.txt")
    try "precious".write(to: keep, atomically: true, encoding: .utf8)
    let store = makeStore(
      sandbox: sandbox,
      worktrees: [makeWorktree(at: sandbox.repoURL, branch: "main", sandbox: sandbox)]
    )

    await store.send(
      .createWorktreeInRepository(
        repositoryID: RepositoryID(sandbox.repoURL.path(percentEncoded: false)),
        nameSource: .explicit("feature"),
        // An unresolvable base ref makes `wt` fail after the name is chosen.
        baseRefSource: .explicit("does-not-exist"),
        fetchOrigin: false,
        placement: WorktreePlacementOverride(
          path: sandbox.root.appending(path: "elsewhere").path(percentEncoded: false))
      )
    )
    await store.receive(\.createRandomWorktreeFailed, timeout: .seconds(60))
    await store.finish(timeout: .seconds(60))

    #expect(FileManager.default.fileExists(atPath: keep.path(percentEncoded: false)))
  }

  private func useSandboxBase(_ sandbox: Sandbox) {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock {
      $0.global.defaultWorktreeBaseDirectoryPath = sandbox.root.appending(path: "base").path(percentEncoded: false)
      $0.global.copyIgnoredOnWorktreeCreate = false
      $0.global.copyUntrackedOnWorktreeCreate = false
    }
  }

  private func branchExists(_ name: String, in sandbox: Sandbox) async throws -> Bool {
    let output = try await Sandbox.git([
      "-C", sandbox.repoURL.path(percentEncoded: false), "for-each-ref", "--format=%(refname)", "refs/heads/\(name)",
    ])
    return output.trimmingCharacters(in: .whitespacesAndNewlines) == "refs/heads/\(name)"
  }

  @Test(.dependencies) func successfulCreationIsOwnedAndKept() async throws {
    let sandbox = try await Sandbox()
    defer { sandbox.cleanup() }
    useSandboxBase(sandbox)
    let store = makeStore(
      sandbox: sandbox,
      worktrees: [makeWorktree(at: sandbox.repoURL, branch: "main", sandbox: sandbox)]
    )

    await store.send(
      .createWorktreeInRepository(
        repositoryID: RepositoryID(sandbox.repoURL.path(percentEncoded: false)),
        nameSource: .explicit("feature"),
        baseRefSource: .repositorySetting,
        fetchOrigin: false
      )
    )
    // The real `wt` output must prove ownership, or a later cancel would leak the worktree.
    await store.receive(
      { action in
        guard case .createRandomWorktreeSucceeded(_, _, _, .created) = action else { return false }
        return true
      },
      timeout: .seconds(60)
    )
    await store.finish(timeout: .seconds(60))

    let created = sandbox.baseDirectory.appending(path: "feature/.git")
    #expect(FileManager.default.fileExists(atPath: created.path(percentEncoded: false)))
    #expect(try await branchExists("feature", in: sandbox))
  }

  @Test(.dependencies) func cancelledCreationIsRemoved() async throws {
    let sandbox = try await Sandbox()
    defer { sandbox.cleanup() }
    useSandboxBase(sandbox)
    let store = makeStore(
      sandbox: sandbox,
      worktrees: [makeWorktree(at: sandbox.repoURL, branch: "main", sandbox: sandbox)]
    )
    let pendingID = WorktreeID("\(WorktreeID.pendingPrefix)gh878-cancel")

    await store.send(
      .createWorktreeInRepository(
        repositoryID: RepositoryID(sandbox.repoURL.path(percentEncoded: false)),
        nameSource: .explicit("feature"),
        baseRefSource: .repositorySetting,
        fetchOrigin: false,
        pendingID: pendingID
      )
    )
    await store.send(.cancelPendingWorktree(pendingID))
    await store.receive(\.createRandomWorktreeSucceeded, timeout: .seconds(60))
    await store.finish(timeout: .seconds(60))

    let created = sandbox.baseDirectory.appending(path: "feature", directoryHint: .isDirectory)
    #expect(!FileManager.default.fileExists(atPath: created.path(percentEncoded: false)))
    #expect(try await !branchExists("feature", in: sandbox))
  }

  @Test(.dependencies) func failureAfterWorktreeAddIsCleanedUp() async throws {
    let sandbox = try await Sandbox()
    defer { sandbox.cleanup() }
    useSandboxBase(sandbox)
    // A failing post-checkout hook leaves git's worktree registered while `wt` exits non-zero.
    let hook = sandbox.repoURL.appending(path: ".git/hooks/post-checkout")
    try FileManager.default.createDirectory(at: hook.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "#!/bin/sh\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path(percentEncoded: false))
    let store = makeStore(
      sandbox: sandbox,
      worktrees: [makeWorktree(at: sandbox.repoURL, branch: "main", sandbox: sandbox)]
    )

    await store.send(
      .createWorktreeInRepository(
        repositoryID: RepositoryID(sandbox.repoURL.path(percentEncoded: false)),
        nameSource: .explicit("feature"),
        baseRefSource: .repositorySetting,
        fetchOrigin: false
      )
    )
    await store.receive(\.createRandomWorktreeFailed, timeout: .seconds(60))
    await store.finish(timeout: .seconds(60))

    let created = sandbox.baseDirectory.appending(path: "feature", directoryHint: .isDirectory)
    #expect(!FileManager.default.fileExists(atPath: created.path(percentEncoded: false)))
    #expect(try await !branchExists("feature", in: sandbox))
  }

  @Test func localBranchNamesKeepsBranchShadowedByTag() async throws {
    let sandbox = try await Sandbox()
    defer { sandbox.cleanup() }
    let repoPath = sandbox.repoURL.path(percentEncoded: false)
    try await Sandbox.git(["-C", repoPath, "branch", "foo"])
    try await Sandbox.git(["-C", repoPath, "tag", "foo"])

    let branches = try await GitClient().localBranchNames(for: sandbox.repoURL)
    #expect(branches.contains("foo"))
  }

  @Test func symlinkToEmptyFolderCountsAsContent() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "gh878-link-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let empty = root.appending(path: "empty")
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    let link = root.appending(path: "link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: empty)

    #expect(GitClient.destinationHasContent(at: link))
    #expect(GitClient.destinationHasContent(at: root.appending(path: "link", directoryHint: .isDirectory)))
  }
}
