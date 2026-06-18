import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import OrderedCollections
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

struct RemoteRepositoryConfigTests {
  @Test func normalizedRemotePathTrimsTrailingSlashesAndWhitespace() {
    let config = RemoteRepositoryConfig(
      host: RemoteHost(alias: "devbox"),
      remotePath: "  /home/me/proj//  ",
      displayName: ""
    )
    #expect(config.normalizedRemotePath == "/home/me/proj")
  }

  @Test func normalizedRemotePathKeepsRootSlash() {
    let config = RemoteRepositoryConfig(host: RemoteHost(alias: "devbox"), remotePath: "/", displayName: "")
    #expect(config.normalizedRemotePath == "/")
  }

  @Test func resolvedDisplayNameFallsBackToRemoteLeaf() {
    let config = RemoteRepositoryConfig(
      host: RemoteHost(alias: "devbox"),
      remotePath: "/home/me/proj",
      displayName: "  "
    )
    #expect(config.resolvedDisplayName == "proj")
  }

  @Test func resolvedDisplayNamePrefersExplicitName() {
    let config = RemoteRepositoryConfig(
      host: RemoteHost(alias: "devbox"),
      remotePath: "/home/me/proj",
      displayName: "My Proj"
    )
    #expect(config.resolvedDisplayName == "My Proj")
  }
}

struct RemoteRepositoryHelpersTests {
  @Test func remoteRepositoryIDIsHostKeyedAndPrefixed() {
    let config = RemoteRepositoryConfig(host: RemoteHost(alias: "devbox"), remotePath: "/tmp/repo", displayName: "repo")
    let id = RepositoriesFeature.remoteRepositoryID(for: config)
    #expect(id == "remote://devbox/tmp/repo")
    // Never collides with a local repository id (an absolute filesystem path).
    #expect(id != "/tmp/repo")
  }

  @Test func remoteWorktreeIDIsHostKeyed() {
    let id = RepositoriesFeature.remoteWorktreeID(host: RemoteHost(alias: "devbox"), worktreePath: "/tmp/repo/wt")
    #expect(id == "remote://devbox/tmp/repo/wt")
  }

  @Test func remoteWorktreeInjectsHostAndHostKeyedID() {
    let host = RemoteHost(alias: "devbox", username: "alice")
    let base = Worktree(
      id: "/home/alice/proj/feature",
      name: "feature",
      detail: "feature",
      workingDirectory: URL(fileURLWithPath: "/home/alice/proj/feature"),
      repositoryRootURL: URL(fileURLWithPath: "/home/alice/proj")
    )
    let rekeyed = RepositoriesFeature.remoteWorktree(from: base, host: host)
    #expect(rekeyed.host?.sshDestination == "alice@devbox")
    #expect(rekeyed.id == "remote://alice@devbox/home/alice/proj/feature")
    #expect(rekeyed.name == "feature")
    #expect(rekeyed.workingDirectory == base.workingDirectory)
  }

  @Test func remoteMainWorktreeIsGitMainWithHost() {
    let config = RemoteRepositoryConfig(
      host: RemoteHost(alias: "devbox"),
      remotePath: "/home/me/proj",
      displayName: "proj"
    )
    let main = RepositoriesFeature.remoteMainWorktree(config: config)
    #expect(main.host?.sshDestination == "devbox")
    // workingDirectory == repositoryRootURL → classifies as the git main worktree.
    #expect(main.workingDirectory == main.repositoryRootURL)
    #expect(main.id == "remote://devbox/home/me/proj")
  }
}

@MainActor
struct RemoteSidebarMergedListTests {
  private func localRepository() -> Repository {
    let root = URL(fileURLWithPath: "/tmp/localrepo")
    let main = Worktree(
      id: WorktreeID(root.path(percentEncoded: false)),
      name: "main",
      detail: "",
      workingDirectory: root,
      repositoryRootURL: root
    )
    return Repository(
      id: RepositoryID(root.path(percentEncoded: false)),
      rootURL: root,
      name: "localrepo",
      worktrees: IdentifiedArray(uniqueElements: [main])
    )
  }

  private func remoteRepository(config: RemoteRepositoryConfig) -> Repository {
    Repository(
      id: RepositoriesFeature.remoteRepositoryID(for: config),
      rootURL: URL(fileURLWithPath: config.normalizedRemotePath),
      name: config.resolvedDisplayName,
      worktrees: IdentifiedArray(uniqueElements: [RepositoriesFeature.remoteMainWorktree(config: config)]),
      isGitRepository: true,
      host: config.host
    )
  }

  private func makeState(repositories: [Repository]) -> RepositoriesFeature.State {
    var state = RepositoriesFeature.State(reconciledRepositories: repositories)
    state.isInitialLoadComplete = true
    return state
  }

  @Test func remoteRepoRendersInlineAfterLocalWithoutPartitionHeaders() {
    let config = RemoteRepositoryConfig(
      host: RemoteHost(alias: "devbox"),
      remotePath: "/home/me/proj",
      displayName: "proj"
    )
    let local = localRepository()
    let state = makeState(repositories: [local, remoteRepository(config: config)])

    let structure = state.computeSidebarStructure(groupPinned: false, groupActive: false)

    // Every section is a real repository section: no synthetic divider rows.
    let repoIDs: [Repository.ID] = structure.sections.compactMap { section in
      if case .repository(let repositoryID, _) = section { return repositoryID }
      return nil
    }
    #expect(repoIDs.count == structure.sections.count)

    // Local repo precedes the remote repo in the merged, flat list.
    let remoteRepoID = RepositoriesFeature.remoteRepositoryID(for: config)
    #expect(repoIDs == [local.id, remoteRepoID])

    // The remote repo's tag is flagged remote so the subtitle / header can mark it.
    // (No row is hoisted here, so `repositoryHighlightByID` is empty; the inline
    // section header reads `repository.host != nil` directly.)
    #expect(state.repositories[id: remoteRepoID]?.host != nil)
  }

  @Test func orderedRepositoryIDsIncludesRemoteRepos() {
    let config = RemoteRepositoryConfig(
      host: RemoteHost(alias: "devbox"),
      remotePath: "/home/me/proj",
      displayName: "proj"
    )
    let local = localRepository()
    let state = makeState(repositories: [local, remoteRepository(config: config)])
    let ids = state.orderedRepositoryIDs()
    // Remote repos (host-keyed ids, not local roots) must appear so the pinned
    // hoist, hotkeys, and arrow-nav can see remote rows.
    #expect(ids.contains(local.id))
    #expect(ids.contains(RepositoriesFeature.remoteRepositoryID(for: config)))
  }

  @Test func remoteRepositoriesAreReorderable() {
    let config = RemoteRepositoryConfig(
      host: RemoteHost(alias: "devbox"),
      remotePath: "/home/me/proj",
      displayName: "proj"
    )
    let local = localRepository()
    let remote = remoteRepository(config: config)
    let state = makeState(repositories: [local, remote])

    let structure = state.computeSidebarStructure(groupPinned: false, groupActive: false)

    // A remote repo is a first-class drag target, not pinned below the locals.
    #expect(structure.reorderableRepositoryIDs.contains(remote.id))
    // `reorderableRepositoryIDs` mirrors `orderedRepositoryIDs()` 1:1 so the
    // offset-based `.repositoriesMoved` maps cleanly.
    #expect(structure.reorderableRepositoryIDs == state.orderedRepositoryIDs())
  }

  @Test func persistedSidebarOrderInterleavesRemoteAndLocal() {
    let config = RemoteRepositoryConfig(
      host: RemoteHost(alias: "devbox"),
      remotePath: "/home/me/proj",
      displayName: "proj"
    )
    let local = localRepository()
    let remote = remoteRepository(config: config)
    var state = makeState(repositories: [local, remote])
    // Simulate a drag that placed the remote repo above the local one.
    state.$sidebar.withLock { sidebar in
      var sections: OrderedDictionary<Repository.ID, SidebarState.Section> = [:]
      sections[remote.id] = .init()
      sections[local.id] = .init()
      sidebar.sections = sections
    }

    #expect(state.orderedRepositoryIDs() == [remote.id, local.id])

    let structure = state.computeSidebarStructure(groupPinned: false, groupActive: false)
    let repoIDs: [Repository.ID] = structure.sections.compactMap { section in
      if case .repository(let repositoryID, _) = section { return repositoryID }
      return nil
    }
    #expect(repoIDs == [remote.id, local.id])
  }

  @Test func repositoriesMovedReordersRemoteAboveLocal() async {
    let config = RemoteRepositoryConfig(
      host: RemoteHost(alias: "devbox"),
      remotePath: "/home/me/proj",
      displayName: "proj"
    )
    let local = localRepository()
    let remote = remoteRepository(config: config)
    let state = makeState(repositories: [local, remote])
    // Default order before any drag: local then remote.
    #expect(state.orderedRepositoryIDs() == [local.id, remote.id])

    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.sidebarStructureAutoRecompute = false
    }
    // The move rewrites the persisted `sidebar.sections` order plus derived
    // caches; this test only asserts the resulting repository order.
    store.exhaustivity = .off

    // Drag the remote repo (index 1) to the top.
    await store.send(.repositoriesMoved([1], 0))
    #expect(store.state.orderedRepositoryIDs() == [remote.id, local.id])
    let sectionOrder = Array(store.state.sidebar.sections.keys)
    #expect(sectionOrder == [remote.id, local.id])
  }

  @Test func localOnlySidebarRendersFlatRepositorySections() {
    let local = localRepository()
    let state = makeState(repositories: [local])

    let structure = state.computeSidebarStructure(groupPinned: false, groupActive: false)
    let repoIDs: [Repository.ID] = structure.sections.compactMap { section in
      if case .repository(let repositoryID, _) = section { return repositoryID }
      return nil
    }
    #expect(repoIDs == [local.id])
  }

  @Test func nonGitRemoteRendersAsFolderSection() {
    let config = RemoteRepositoryConfig(
      host: RemoteHost(alias: "devbox"),
      remotePath: "/home/me/docs",
      displayName: "docs"
    )
    let repoID = RepositoriesFeature.remoteRepositoryID(for: config)
    let folderRepo = RepositoriesFeature.remoteFolderRepository(config: config, repoID: repoID)
    let state = makeState(repositories: [folderRepo])

    let structure = state.computeSidebarStructure(groupPinned: false, groupActive: false)
    // Folder-synthetic id (`folder:` + host-keyed remote repo id) so a remote folder
    // never collides with a local one at the same path.
    let folderRowID = WorktreeID.folder(repositoryID: repoID)
    let rendersFolder = structure.sections.contains { section in
      if case .folder(let id, let rowID) = section { return id == repoID && rowID == folderRowID }
      return false
    }
    #expect(rendersFolder)
    // Never a git repository section for a non-git remote path.
    let rendersRepository = structure.sections.contains { section in
      if case .repository = section { return true }
      return false
    }
    #expect(!rendersRepository)
  }

  @Test func disconnectedRemoteRendersAsFailedPlaceholderNotPruned() {
    let config = RemoteRepositoryConfig(
      host: RemoteHost(alias: "devbox"),
      remotePath: "/home/me/proj",
      displayName: "proj"
    )
    let repoID = RepositoriesFeature.remoteRepositoryID(for: config)
    // The loader keeps an empty placeholder repository for an unreachable host.
    let placeholder = Repository(
      id: repoID,
      rootURL: URL(fileURLWithPath: "/home/me/proj"),
      name: "proj",
      worktrees: [],
      isGitRepository: true,
      host: config.host
    )
    var state = makeState(repositories: [placeholder])
    state.loadFailuresByID[repoID] = "Can't reach devbox."

    let structure = state.computeSidebarStructure(groupPinned: false, groupActive: false)
    let rendersFailedRemote = structure.sections.contains { section in
      if case .failedRepository(let id, _, _, _, let isRemote) = section { return id == repoID && isRemote }
      return false
    }
    #expect(rendersFailedRemote)
    // It is not pruned, and not rendered as a normal repository / folder section.
    let rendersRepository = structure.sections.contains { section in
      if case .repository = section { return true }
      return false
    }
    #expect(!rendersRepository)
  }
}

@MainActor
struct RemoteDefaultShellCommandTests {
  @Test func buildsCdIntoRemotePathThenExecLoginShell() {
    #expect(
      WorktreeTerminalState.remoteDefaultShellCommand(remotePath: "/home/me/proj")
        == "cd '/home/me/proj' 2>/dev/null; exec \"$SHELL\" -l"
    )
  }

  @Test func escapesSingleQuotesInRemotePath() {
    #expect(
      WorktreeTerminalState.remoteDefaultShellCommand(remotePath: "/home/o'brien/proj")
        == "cd '/home/o'\\''brien/proj' 2>/dev/null; exec \"$SHELL\" -l"
    )
  }

  @Test func nilForRootOrEmptyPath() {
    #expect(WorktreeTerminalState.remoteDefaultShellCommand(remotePath: "/") == nil)
    #expect(WorktreeTerminalState.remoteDefaultShellCommand(remotePath: "   ") == nil)
  }
}

@MainActor
struct RemoteWorktreeInfoTests {
  private func remoteRepository(config: RemoteRepositoryConfig) -> (Repository, Worktree) {
    let worktree = RepositoriesFeature.remoteMainWorktree(config: config)
    let repository = Repository(
      id: RepositoriesFeature.remoteRepositoryID(for: config),
      rootURL: URL(fileURLWithPath: config.normalizedRemotePath),
      name: config.resolvedDisplayName,
      worktrees: IdentifiedArray(uniqueElements: [worktree]),
      isGitRepository: true,
      host: config.host
    )
    return (repository, worktree)
  }

  /// PR refresh runs `gh` against a local checkout, which a remote-only repo
  /// doesn't have, so the reducer must short-circuit to `.none`.
  @Test func pullRequestRefreshSkippedForRemoteRepository() async {
    let config = RemoteRepositoryConfig(
      host: RemoteHost(alias: "devbox"),
      remotePath: "/home/me/proj",
      displayName: "proj"
    )
    let (repository, worktree) = remoteRepository(config: config)
    var state = RepositoriesFeature.State(reconciledRepositories: [repository])
    state.isInitialLoadComplete = true

    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.sidebarStructureAutoRecompute = false
    }

    // No state change and no effects: the host guard returns before any `gh`
    // work, so an exhaustive TestStore send with no trailing closure passes.
    await store.send(
      .worktreeInfoEvent(
        .repositoryPullRequestRefresh(repositoryRootURL: repository.rootURL, worktreeIDs: [worktree.id])
      )
    )
  }

  /// The remote-add flow presents a reducer-driven form (so errors can surface
  /// inline); cancelling dismisses it.
  @Test func requestAddRemoteRepositoryPresentsFormAndCancelDismisses() async {
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.sidebarStructureAutoRecompute = false
    }

    await store.send(.requestAddRemoteRepository) {
      $0.remoteConnectionForm = RemoteConnectionFormFeature.State(mode: .add)
    }
    await store.send(.remoteConnectionForm(.presented(.delegate(.cancel)))) {
      $0.remoteConnectionForm = nil
    }
  }
}

@MainActor
struct RemoteConnectionFormFeatureTests {
  @Test func bindingClearsStaleValidationMessage() async {
    var initial = RemoteConnectionFormFeature.State(mode: .add, server: "devbox")
    initial.validationMessage = "stale"
    let store = TestStore(initialState: initial) { RemoteConnectionFormFeature() }
    await store.send(.binding(.set(\.remotePath, "~/proj"))) {
      $0.remotePath = "~/proj"
      $0.validationMessage = nil
    }
  }

  @Test func failedResolutionShowsFooterMessageAndStaysOpen() async {
    var initial = RemoteConnectionFormFeature.State(mode: .add, server: "devbox", remotePath: "~/proj")
    initial.isValidating = true
    let store = TestStore(initialState: initial) { RemoteConnectionFormFeature() }
    await store.send(.resolutionFinished(absolutePath: nil)) {
      $0.isValidating = false
      $0.validationMessage =
        "Couldn't reach devbox or find ~/proj. Check the server, port, user, and path."
    }
  }

  @Test func successfulResolutionDelegatesSaveWithAbsolutePath() async {
    var initial = RemoteConnectionFormFeature.State(mode: .add, server: "devbox", remotePath: "~/proj")
    initial.isValidating = true
    let store = TestStore(initialState: initial) { RemoteConnectionFormFeature() }
    await store.send(.resolutionFinished(absolutePath: "/home/me/proj")) {
      $0.isValidating = false
    }
    await store.receive(\.delegate)
  }

  @Test func cancelDelegatesCancel() async {
    let store = TestStore(initialState: RemoteConnectionFormFeature.State(mode: .add)) {
      RemoteConnectionFormFeature()
    }
    await store.send(.cancelButtonTapped)
    await store.receive(\.delegate)
  }
}

/// `saveRemoteConnection` is the load-bearing persist path the form delegates
/// into: add (append + dedup), edit (replace by id), and host/path re-key (drop
/// the orphaned per-repo customization). The form-feature tests stop at the
/// delegate; these drive `.remoteConnectionForm(.presented(.delegate(.save)))`
/// against the real `RepositoriesFeature` reducer to cover the persist itself.
@MainActor
struct SaveRemoteConnectionTests {
  /// Run `body` with the settings-file dependencies pinned to a per-test
  /// in-memory storage so the reducer's `@Shared(.settingsFile)` mutations and
  /// the test body's reads resolve the same key (the key captures
  /// `settingsFileURL` at construction). The `.dependencies` trait isolates
  /// shared state per test.
  private func withRemoteStore(
    _ body: (TestStoreOf<RepositoriesFeature>) async -> Void
  ) async {
    let storage = SettingsTestStorage()
    let settingsFileURL = URL(fileURLWithPath: "/tmp/supacode-remote-save-\(UUID().uuidString).json")
    await withDependencies {
      $0.settingsFileStorage = storage.storage
      $0.settingsFileURL = settingsFileURL
      $0.sidebarStructureAutoRecompute = false
    } operation: {
      let store = TestStore(initialState: RepositoriesFeature.State()) {
        RepositoriesFeature()
      }
      // The save handler reloads; we only assert the synchronous persist, so let
      // the reducer ignore everything past the `save` send.
      store.exhaustivity = .off
      await body(store)
    }
  }

  private func remoteRepositories() -> [RemoteRepositoryConfig] {
    @Shared(.settingsFile) var settingsFile
    return settingsFile.global.remoteRepositories
  }

  @Test(.dependencies) func addAppendsNewConfig() async {
    await withRemoteStore { store in
      let config = RemoteRepositoryConfig(
        host: RemoteHost(alias: "devbox"),
        remotePath: "/home/me/proj",
        displayName: ""
      )

      await store.send(.requestAddRemoteRepository) {
        $0.remoteConnectionForm = RemoteConnectionFormFeature.State(mode: .add)
      }
      await store.send(.remoteConnectionForm(.presented(.delegate(.save(config)))))
      await store.finish()

      let configs = remoteRepositories()
      #expect(configs.map(\.id) == [config.id])
      #expect(configs.first?.normalizedRemotePath == "/home/me/proj")
    }
  }

  @Test(.dependencies) func editReplacesConfigByIDInPlace() async {
    await withRemoteStore { store in
      let original = RemoteRepositoryConfig(
        host: RemoteHost(alias: "devbox"),
        remotePath: "/home/me/proj",
        displayName: "old"
      )
      let originalRepositoryID = RepositoriesFeature.remoteRepositoryID(for: original)

      @Shared(.settingsFile) var settingsFile
      $settingsFile.withLock { $0.global.remoteRepositories = [original] }

      // Same host/path (so the id is unchanged) but a new display name.
      let edited = RemoteRepositoryConfig(
        id: original.id,
        host: RemoteHost(alias: "devbox"),
        remotePath: "/home/me/proj",
        displayName: "new"
      )

      await store.send(.requestEditRemoteRepository(originalRepositoryID)) {
        $0.remoteConnectionForm = RemoteConnectionFormFeature.State.editing(
          original, repositoryID: originalRepositoryID)
      }
      await store.send(.remoteConnectionForm(.presented(.delegate(.save(edited)))))
      await store.finish()

      let configs = remoteRepositories()
      // Replaced in place by id: still a single entry, now carrying the new name.
      #expect(configs.count == 1)
      #expect(configs.first?.id == original.id)
      #expect(configs.first?.displayName == "new")
    }
  }

  @Test(.dependencies) func editReKeyingHostOrPathDropsOrphanedCustomization() async {
    await withRemoteStore { store in
      let original = RemoteRepositoryConfig(
        host: RemoteHost(alias: "devbox"),
        remotePath: "/home/me/proj",
        displayName: ""
      )
      let originalRepositoryID = RepositoriesFeature.remoteRepositoryID(for: original)

      @Shared(.settingsFile) var settingsFile
      $settingsFile.withLock { $0.global.remoteRepositories = [original] }
      // Seed per-repo customization under the original id; the re-key must drop it.
      @Shared(.sidebar) var sidebar
      $sidebar.withLock {
        $0.sections[originalRepositoryID, default: .init()].title = "Custom Title"
      }
      #expect(store.state.sidebar.sections[originalRepositoryID] != nil)

      // Re-key by editing the path; the derived id changes.
      let edited = RemoteRepositoryConfig(
        id: original.id,
        host: RemoteHost(alias: "devbox"),
        remotePath: "/home/me/other",
        displayName: ""
      )
      #expect(RepositoriesFeature.remoteRepositoryID(for: edited) != originalRepositoryID)

      await store.send(.requestEditRemoteRepository(originalRepositoryID)) {
        $0.remoteConnectionForm = RemoteConnectionFormFeature.State.editing(
          original, repositoryID: originalRepositoryID)
      }
      await store.send(.remoteConnectionForm(.presented(.delegate(.save(edited)))))
      await store.finish()

      // The orphaned customization under the old id is dropped.
      #expect(store.state.sidebar.sections[originalRepositoryID] == nil)
      // The replaced config persists at the new path.
      #expect(remoteRepositories().first?.normalizedRemotePath == "/home/me/other")
    }
  }

  @Test(.dependencies) func addOfDuplicateHostAndPathIsDeduped() async {
    await withRemoteStore { store in
      let existing = RemoteRepositoryConfig(
        host: RemoteHost(alias: "devbox"),
        remotePath: "/home/me/proj",
        displayName: ""
      )

      @Shared(.settingsFile) var settingsFile
      $settingsFile.withLock { $0.global.remoteRepositories = [existing] }

      // A different config id, but the same (host, normalizedRemotePath); a
      // trailing slash normalizes to the same path so it must not append twice.
      let duplicate = RemoteRepositoryConfig(
        host: RemoteHost(alias: "devbox"),
        remotePath: "/home/me/proj/",
        displayName: "dupe"
      )
      #expect(duplicate.id != existing.id)

      await store.send(.requestAddRemoteRepository) {
        $0.remoteConnectionForm = RemoteConnectionFormFeature.State(mode: .add)
      }
      await store.send(.remoteConnectionForm(.presented(.delegate(.save(duplicate)))))
      await store.finish()

      let configs = remoteRepositories()
      #expect(configs.count == 1)
      #expect(configs.first?.id == existing.id)
    }
  }

  @Test(.dependencies) func addOfPortDistinctConnectionAppendsSeparately() async {
    await withRemoteStore { store in
      let existing = RemoteRepositoryConfig(
        host: RemoteHost(alias: "devbox", port: 22),
        remotePath: "/home/me/proj",
        displayName: ""
      )

      @Shared(.settingsFile) var settingsFile
      $settingsFile.withLock { $0.global.remoteRepositories = [existing] }

      // Same host alias and path, different SSH port: a distinct repository id,
      // so it must be kept rather than deduped against the port-22 connection.
      let otherPort = RemoteRepositoryConfig(
        host: RemoteHost(alias: "devbox", port: 2222),
        remotePath: "/home/me/proj",
        displayName: ""
      )
      #expect(
        RepositoriesFeature.remoteRepositoryID(for: otherPort)
          != RepositoriesFeature.remoteRepositoryID(for: existing)
      )

      await store.send(.requestAddRemoteRepository) {
        $0.remoteConnectionForm = RemoteConnectionFormFeature.State(mode: .add)
      }
      await store.send(.remoteConnectionForm(.presented(.delegate(.save(otherPort)))))
      await store.finish()

      #expect(remoteRepositories().count == 2)
    }
  }

  @Test(.dependencies) func removeRemoteRepositoryDropsMatchingConfigAndCustomization() async {
    await withRemoteStore { store in
      let target = RemoteRepositoryConfig(
        host: RemoteHost(alias: "devbox"),
        remotePath: "/home/me/proj",
        displayName: ""
      )
      let other = RemoteRepositoryConfig(
        host: RemoteHost(alias: "devbox"),
        remotePath: "/home/me/other",
        displayName: ""
      )
      let targetID = RepositoriesFeature.remoteRepositoryID(for: target)

      @Shared(.settingsFile) var settingsFile
      $settingsFile.withLock { $0.global.remoteRepositories = [target, other] }
      @Shared(.sidebar) var sidebar
      $sidebar.withLock { $0.sections[targetID, default: .init()].title = "Custom Title" }

      await store.send(.removeRemoteRepository(targetID))
      await store.finish()

      let configs = remoteRepositories()
      // Only the matching config is dropped; the sibling survives.
      #expect(configs.count == 1)
      #expect(configs.first?.id == other.id)
      // The orphaned per-repo customization is dropped with it.
      #expect(store.state.sidebar.sections[targetID] == nil)
    }
  }
}

struct RemotePathClassificationTests {
  private func stubShell(stdout: String) -> ShellClient {
    ShellClient(
      run: { _, _, _ in ShellOutput(stdout: stdout, stderr: "", exitCode: 0) },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
  }

  private func throwingShell() -> ShellClient {
    ShellClient(
      run: { _, _, _ in throw ShellClientError(command: "probe", stdout: "", stderr: "", exitCode: 1) },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
  }

  /// Routes the `git worktree list` call and the classify probe to separate
  /// stubs so resolution branches can be exercised independently.
  private func routingShell(worktreeList: Result<String, Error>, classifyStdout: String) -> ShellClient {
    ShellClient(
      run: { _, args, _ in
        if args.contains("worktree") {
          switch worktreeList {
          case .success(let stdout): return ShellOutput(stdout: stdout, stderr: "", exitCode: 0)
          case .failure(let error): throw error
          }
        }
        return ShellOutput(stdout: classifyStdout, stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
  }

  private func resolveConfig(path: String = "/srv/repo") -> RemoteRepositoryConfig {
    RemoteRepositoryConfig(host: RemoteHost(alias: "devbox"), remotePath: path, displayName: "repo")
  }

  @Test func listingThrowOnGitRepoSurfacesFailureInsteadOfFakeMain() async {
    let config = resolveConfig()
    let repoID = RepositoriesFeature.remoteRepositoryID(for: config)
    // The listing fails transiently while the host stays reachable (classify
    // still resolves `.git`): we must not collapse to a single fake main.
    let shell = routingShell(
      worktreeList: .failure(ShellClientError(command: "git", stdout: "", stderr: "", exitCode: 1)),
      classifyStdout: "supacode-git"
    )
    let loaded = await RepositoriesFeature.loadRemoteRepository(config, repoID: repoID, shell: shell)
    #expect(loaded.repository.worktrees.isEmpty)
    #expect(loaded.failure?.message.contains("couldn't list worktrees") == true)
  }

  @Test func emptyListingOnGitRepoFallsBackToSyntheticMain() async {
    let config = resolveConfig()
    let repoID = RepositoriesFeature.remoteRepositoryID(for: config)
    // A clean but empty listing is genuine: a single synthetic main is correct.
    let shell = routingShell(worktreeList: .success(""), classifyStdout: "supacode-git")
    let loaded = await RepositoriesFeature.loadRemoteRepository(config, repoID: repoID, shell: shell)
    #expect(loaded.failure == nil)
    #expect(loaded.repository.worktrees.count == 1)
    #expect(loaded.repository.worktrees.first?.id == RepositoriesFeature.remoteMainWorktree(config: config).id)
  }

  @Test func missingPathSurfacesPathNotFoundRatherThanCantReach() async {
    let config = resolveConfig(path: "/srv/gone")
    let repoID = RepositoriesFeature.remoteRepositoryID(for: config)
    let shell = routingShell(
      worktreeList: .failure(ShellClientError(command: "git", stdout: "", stderr: "", exitCode: 1)),
      classifyStdout: "supacode-nodir"
    )
    let loaded = await RepositoriesFeature.loadRemoteRepository(config, repoID: repoID, shell: shell)
    #expect(loaded.repository.worktrees.isEmpty)
    #expect(loaded.failure?.message.contains("was not found") == true)
    #expect(loaded.failure?.message.contains("Can't reach") == false)
  }

  @Test func gitWorkTreeClassifiesAsGit() async {
    let kind = await RepositoriesFeature.classifyRemotePath("/p", shell: stubShell(stdout: "supacode-git"))
    #expect(kind == .git)
  }

  @Test func plainDirectoryClassifiesAsFolder() async {
    let kind = await RepositoriesFeature.classifyRemotePath("/p", shell: stubShell(stdout: "supacode-folder"))
    #expect(kind == .folder)
  }

  @Test func missingDirClassifiesAsMissingAndShellErrorAsUnknown() async {
    // A reachable host with an absent path is `.missing`, not `.unknown`, so the
    // failure can name the path instead of blaming the connection.
    #expect(await RepositoriesFeature.classifyRemotePath("/p", shell: stubShell(stdout: "supacode-nodir")) == .missing)
    #expect(await RepositoriesFeature.classifyRemotePath("/p", shell: throwingShell()) == .unknown)
  }

  @Test func resolveRemotePathReturnsRemoteCanonicalPath() async {
    let host = RemoteHost(alias: "devbox")
    let resolved = await RepositoriesFeature.resolveRemotePath(
      "~/proj", host: host, shell: stubShell(stdout: "/home/me/proj\n"))
    #expect(resolved == "/home/me/proj")
  }

  @Test func resolveRemotePathRejectsBlankAndUnreachable() async {
    let host = RemoteHost(alias: "devbox")
    #expect(await RepositoriesFeature.resolveRemotePath("  ", host: host, shell: stubShell(stdout: "/x")) == nil)
    #expect(await RepositoriesFeature.resolveRemotePath("~/proj", host: host, shell: stubShell(stdout: "")) == nil)
    #expect(await RepositoriesFeature.resolveRemotePath("~/proj", host: host, shell: throwingShell()) == nil)
  }

  @Test func resolveRemotePathIgnoresLoginShellBanner() async {
    let host = RemoteHost(alias: "devbox")
    // A login shell prints dotfile chatter before the probe's `pwd -P` output;
    // the resolved path is the last line, not the banner.
    let resolved = await RepositoriesFeature.resolveRemotePath(
      "~/proj", host: host, shell: stubShell(stdout: "Welcome to devbox!\nmotd line 2\n/home/me/proj\n"))
    #expect(resolved == "/home/me/proj")
  }

  @Test func classifyRemotePathIgnoresLoginShellBanner() async {
    let kind = await RepositoriesFeature.classifyRemotePath(
      "/p", shell: stubShell(stdout: "Welcome to devbox!\nsupacode-git\n"))
    #expect(kind == .git)
  }

  @Test func resolveRemotePathTimesOutOnAHangingProbe() async {
    let host = RemoteHost(alias: "devbox")
    // A shell that never returns in time stands in for an unreachable host that
    // accepts the connection but stalls; the timeout must reject it.
    let hanging = ShellClient(
      run: { _, _, _ in
        try await Task.sleep(for: .seconds(5))
        return ShellOutput(stdout: "/home/me/proj", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let resolved = await RepositoriesFeature.resolveRemotePath(
      "~/proj", host: host, shell: hanging, timeout: .milliseconds(50))
    #expect(resolved == nil)
  }

  @Test func parseRemoteWorktreeBaseDirectoriesExtractsPerRepoAndGlobal() throws {
    var repoSettings = RepositorySettings.default
    repoSettings.worktreeBaseDirectoryPath = "/srv/wt"
    var global = GlobalSettings.default
    global.defaultWorktreeBaseDirectoryPath = "/srv/global"
    let repoJSON = try #require(String(bytes: try JSONEncoder().encode(repoSettings), encoding: .utf8))
    let globalJSON = try #require(
      String(bytes: try JSONEncoder().encode(SettingsFile(global: global)), encoding: .utf8))
    let output = "===SUPACODE-REPO===\n\(repoJSON)\n===SUPACODE-GLOBAL===\n\(globalJSON)"
    let result = RepositoriesFeature.parseRemoteWorktreeBaseDirectories(output)
    #expect(result.perRepo == "/srv/wt")
    #expect(result.global == "/srv/global")
  }

  @Test func parseRemoteWorktreeBaseDirectoriesEmptyForMissingFiles() {
    let result = RepositoriesFeature.parseRemoteWorktreeBaseDirectories(
      "===SUPACODE-REPO===\n===SUPACODE-GLOBAL===\n")
    #expect(result.perRepo == nil)
    #expect(result.global == nil)
  }

  @Test func remoteWorktreeLeafPrefersValidOverrideElseBranch() {
    #expect(RepositoriesFeature.remoteWorktreeLeaf(nameOverride: "custom", branchName: "feature/x") == "custom")
    #expect(RepositoriesFeature.remoteWorktreeLeaf(nameOverride: "  ", branchName: "feature/x") == "feature/x")
    // A slash override would escape the parent, so fall back to the branch name.
    #expect(RepositoriesFeature.remoteWorktreeLeaf(nameOverride: "a/b", branchName: "feat") == "feat")
  }

  @Test func remoteFolderRepositoryIsNonGitFolderCarryingHost() {
    let config = RemoteRepositoryConfig(
      host: RemoteHost(alias: "devbox"),
      remotePath: "/home/me/docs",
      displayName: ""
    )
    let repoID = RepositoriesFeature.remoteRepositoryID(for: config)
    let repo = RepositoriesFeature.remoteFolderRepository(config: config, repoID: repoID)

    #expect(repo.isGitRepository == false)
    #expect(repo.host?.sshDestination == "devbox")
    #expect(repo.worktrees.count == 1)
    let folder = repo.worktrees.elements.first
    // Folder-synthetic id: the `folder:` marker composed with the host-keyed remote repo id,
    // so it round-trips to the repo and never collides with a local folder.
    #expect(folder?.id == WorktreeID.folder(repositoryID: repoID))
    #expect(folder?.host?.sshDestination == "devbox")
    #expect(folder?.workingDirectory == URL(fileURLWithPath: "/home/me/docs"))
  }
}

/// `remoteWorktreeParentDirectory` resolves a new remote worktree's parent via a
/// 4-tier precedence chain (explicit override > per-repo > global+repoName >
/// repoRoot parent). It takes an injectable shell so the per-repo / global tiers
/// can be driven from a stubbed `cat` output without touching a real host. A
/// reorder or a dropped `.appending(path:)` on the global branch would silently
/// mis-place worktrees with no coverage; these pin the contract.
@MainActor
struct RemoteWorktreeParentDirectoryTests {
  /// Stub shell whose `cat` emits the marker-separated per-repo + global blocks
  /// that `readRemoteWorktreeBaseDirectories` parses. Passing `nil` for either
  /// path leaves that section empty (a missing remote file).
  private func basesShell(perRepo: String?, global: String?) throws -> ShellClient {
    var repoSettings = RepositorySettings.default
    repoSettings.worktreeBaseDirectoryPath = perRepo ?? ""
    var globalSettings = GlobalSettings.default
    globalSettings.defaultWorktreeBaseDirectoryPath = global ?? ""
    let repoJSON = try #require(String(bytes: try JSONEncoder().encode(repoSettings), encoding: .utf8))
    let globalJSON = try #require(
      String(bytes: try JSONEncoder().encode(SettingsFile(global: globalSettings)), encoding: .utf8))
    let output = "===SUPACODE-REPO===\n\(repoJSON)\n===SUPACODE-GLOBAL===\n\(globalJSON)"
    return ShellClient(
      run: { _, _, _ in ShellOutput(stdout: output, stderr: "", exitCode: 0) },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
  }

  private let host = RemoteHost(alias: "devbox")
  private let repoRoot = URL(fileURLWithPath: "/home/me/proj")

  @Test func explicitPlacementPathWinsAndShortCircuits() async throws {
    // Even with per-repo + global configured, the explicit override wins and the
    // shell is never consulted.
    let parent = await RepositoriesFeature.remoteWorktreeParentDirectory(
      host: host,
      repoRoot: repoRoot,
      placementPath: "/explicit/parent",
      shell: try basesShell(perRepo: "/srv/wt", global: "/srv/global")
    )
    #expect(parent == URL(filePath: "/explicit/parent", directoryHint: .isDirectory))
  }

  @Test func blankExplicitPlacementFallsThroughToPerRepo() async throws {
    // A whitespace-only override is not a placement; precedence continues.
    let parent = await RepositoriesFeature.remoteWorktreeParentDirectory(
      host: host,
      repoRoot: repoRoot,
      placementPath: "   ",
      shell: try basesShell(perRepo: "/srv/wt", global: "/srv/global")
    )
    #expect(parent == URL(filePath: "/srv/wt", directoryHint: .isDirectory))
  }

  @Test func perRepoWinsOverGlobal() async throws {
    let parent = await RepositoriesFeature.remoteWorktreeParentDirectory(
      host: host,
      repoRoot: repoRoot,
      placementPath: nil,
      shell: try basesShell(perRepo: "/srv/wt", global: "/srv/global")
    )
    #expect(parent == URL(filePath: "/srv/wt", directoryHint: .isDirectory))
  }

  @Test func globalAppendsRepoRootLastPathComponent() async throws {
    // The global default is a shared base; the repo's directory name is appended
    // so worktrees for different repos don't collide under it.
    let parent = await RepositoriesFeature.remoteWorktreeParentDirectory(
      host: host,
      repoRoot: repoRoot,
      placementPath: nil,
      shell: try basesShell(perRepo: nil, global: "/srv/global")
    )
    #expect(
      parent
        == URL(filePath: "/srv/global", directoryHint: .isDirectory)
        .appending(path: "proj", directoryHint: .isDirectory)
    )
  }

  @Test func allEmptyFallsBackToRepoRootParent() async throws {
    let parent = await RepositoriesFeature.remoteWorktreeParentDirectory(
      host: host,
      repoRoot: repoRoot,
      placementPath: nil,
      shell: try basesShell(perRepo: nil, global: nil)
    )
    #expect(parent == repoRoot.deletingLastPathComponent())
  }
}

@MainActor
struct RemoteWorktreeBaseRefTests {
  private func emptyRemoteClient() -> GitClient {
    let base = ShellClient(
      run: { _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    return GitClient(shell: .ssh(host: RemoteHost(alias: "devbox"), base: base))
  }

  @Test func explicitBaseRefIsUsedVerbatim() async {
    let ref = await RepositoriesFeature.resolveRemoteBaseRef(
      baseRefSource: .explicit("origin/dev"),
      selectedBaseRef: nil,
      client: emptyRemoteClient(),
      repoRoot: URL(fileURLWithPath: "/repo")
    )
    #expect(ref == "origin/dev")
  }

  @Test func repositorySettingBaseRefIsUsed() async {
    let ref = await RepositoriesFeature.resolveRemoteBaseRef(
      baseRefSource: .repositorySetting,
      selectedBaseRef: "main",
      client: emptyRemoteClient(),
      repoRoot: URL(fileURLWithPath: "/repo")
    )
    #expect(ref == "main")
  }

  @Test func delegatesToRemoteAutomaticBaseRefWhenNoExplicitSelection() async {
    // No explicit ref / repo setting → delegate to the remote's automatic base
    // ref (mirrors local), not a hardcoded HEAD.
    let repoRoot = URL(fileURLWithPath: "/repo")
    let client = emptyRemoteClient()
    let expected = await client.automaticWorktreeBaseRef(for: repoRoot) ?? "HEAD"
    let ref = await RepositoriesFeature.resolveRemoteBaseRef(
      baseRefSource: .repositorySetting,
      selectedBaseRef: "",
      client: client,
      repoRoot: repoRoot
    )
    #expect(ref == expected)
    #expect(!ref.isEmpty)
  }
}

/// Remote worktree creation honors `fetchOriginBeforeWorktreeCreation` the same
/// way local does: when enabled and the base ref carries a `<remote>/` prefix,
/// a `git fetch <remote>` is issued over ssh before `git worktree add`. The
/// recorder stands in for the local `ssh` process; `git remote` returns a single
/// `origin` so prefix matching resolves.
@MainActor
struct RemoteFetchOriginTests {
  private func recordingRemoteClient(_ recorder: GitShellInvocationRecorder) -> GitClient {
    let base = ShellClient(
      run: { exe, args, cwd in
        recorder.record(executableURL: exe, arguments: args, currentDirectoryURL: cwd)
        return ShellOutput(stdout: "origin\n", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "origin\n", stderr: "", exitCode: 0) }
    )
    return GitClient(shell: .ssh(host: RemoteHost(alias: "devbox"), base: base))
  }

  @Test func fetchesMatchingRemoteWhenEnabled() async {
    let recorder = GitShellInvocationRecorder()
    await RepositoriesFeature.fetchRemoteForBaseRefIfNeeded(
      fetchOrigin: true,
      baseRef: "origin/main",
      client: recordingRemoteClient(recorder),
      repoRoot: URL(fileURLWithPath: "/repo")
    )
    // Last ssh invocation is the fetch (it follows `git remote`).
    let wrapped = recorder.snapshot().arguments.last ?? ""
    #expect(wrapped.contains("fetch"))
    #expect(wrapped.contains("origin"))
  }

  @Test func skipsFetchWhenBaseRefHasNoRemotePrefix() async {
    let recorder = GitShellInvocationRecorder()
    await RepositoriesFeature.fetchRemoteForBaseRefIfNeeded(
      fetchOrigin: true,
      baseRef: "main",
      client: recordingRemoteClient(recorder),
      repoRoot: URL(fileURLWithPath: "/repo")
    )
    // Only `git remote` ran (to list); no fetch since `main` has no `<remote>/` prefix.
    let wrapped = recorder.snapshot().arguments.last ?? ""
    #expect(wrapped.contains("remote"))
    #expect(!wrapped.contains("fetch"))
  }

  @Test func skipsEverythingWhenDisabled() async {
    let recorder = GitShellInvocationRecorder()
    await RepositoriesFeature.fetchRemoteForBaseRefIfNeeded(
      fetchOrigin: false,
      baseRef: "origin/main",
      client: recordingRemoteClient(recorder),
      repoRoot: URL(fileURLWithPath: "/repo")
    )
    // The guard returns before listing remotes, so no ssh call is made at all.
    #expect(recorder.snapshot().executableURL == nil)
  }
}

/// In-state worktree mutations must not strip a remote repository's host or kind
/// via a back-compat reconstruction, or a transient window would treat a remote
/// repo as local.
@MainActor
struct RemoteRepositoryStateMutationTests {
  private let host = RemoteHost(alias: "devbox", username: "me")

  private func remoteWorktree(path: String, name: String) -> Worktree {
    Worktree(
      location: .remote(host, workingDirectory: path, repositoryRoot: "/srv/repo"),
      kind: .git,
      name: name,
      detail: ""
    )
  }

  private func makeState(worktrees: [Worktree]) -> (RepositoriesFeature.State, Repository.ID) {
    let repo = Repository(
      location: .remote(host, path: "/srv/repo"),
      kind: .git,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: worktrees)
    )
    var state = RepositoriesFeature.State()
    state.repositories = [repo]
    return (state, repo.id)
  }

  @Test func insertWorktreePreservesRemoteHostAndKind() {
    let (initialState, repoID) = makeState(worktrees: [remoteWorktree(path: "/srv/repo", name: "main")])
    var state = initialState
    let added = remoteWorktree(path: "/srv/repo/feature", name: "feature")
    state.insertWorktree(added, repositoryID: repoID)

    let stored = state.repositories[id: repoID]
    #expect(stored?.host == host)
    #expect(stored?.isGitRepository == true)
    #expect(stored?.worktrees[id: added.id]?.host == host)
  }

  @Test func removeWorktreePreservesRemoteHostAndKind() {
    let feature = remoteWorktree(path: "/srv/repo/feature", name: "feature")
    let (initialState, repoID) = makeState(worktrees: [remoteWorktree(path: "/srv/repo", name: "main"), feature])
    var state = initialState
    _ = state.removeWorktree(feature.id, repositoryID: repoID)

    let stored = state.repositories[id: repoID]
    #expect(stored?.host == host)
    #expect(stored?.isGitRepository == true)
    #expect(stored?.worktrees[id: feature.id] == nil)
  }

  @Test func renameWorktreePreservesRemoteHostKindAndID() {
    let feature = remoteWorktree(path: "/srv/repo/feature", name: "feature")
    let (initialState, repoID) = makeState(worktrees: [remoteWorktree(path: "/srv/repo", name: "main"), feature])
    var state = initialState
    state.updateWorktreeName(feature.id, name: "renamed")

    let stored = state.repositories[id: repoID]
    #expect(stored?.host == host)
    #expect(stored?.isGitRepository == true)
    let renamed = stored?.worktrees[id: feature.id]
    #expect(renamed?.name == "renamed")
    #expect(renamed?.host == host)
    #expect(renamed?.id == feature.id)
  }
}

/// Async remote resolution: the initial load renders placeholders (marked
/// resolving) and `.remoteRepositoryResolved` flips each to loaded or "can't
/// reach" without blocking the sidebar.
@MainActor
struct RemoteRepositoryResolutionTests {
  private let host = RemoteHost(alias: "devbox")

  private func config() -> RemoteRepositoryConfig {
    RemoteRepositoryConfig(host: host, remotePath: "/srv/repo", displayName: "")
  }

  private func resolvedRepository(repoID: Repository.ID) -> Repository {
    let main = Worktree(
      location: .remote(host, workingDirectory: "/srv/repo", repositoryRoot: "/srv/repo"),
      kind: .git,
      name: "main",
      detail: ""
    )
    return Repository(
      location: .remote(host, path: "/srv/repo"),
      kind: .git,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [main])
    )
  }

  private func placeholderState(repoID: Repository.ID, config: RemoteRepositoryConfig) -> RepositoriesFeature.State {
    var state = RepositoriesFeature.State()
    state.isInitialLoadComplete = true
    state.repositories = [RepositoriesFeature.remotePlaceholderRepository(config: config, repoID: repoID)]
    state.resolvingRemoteRepositoryIDs = [repoID]
    return state
  }

  private func withStore(
    _ state: RepositoriesFeature.State,
    _ body: (TestStoreOf<RepositoriesFeature>) async -> Void
  ) async {
    let storage = SettingsTestStorage()
    await withDependencies {
      $0.settingsFileStorage = storage.storage
      $0.settingsFileURL = URL(fileURLWithPath: "/tmp/supacode-remote-resolve-\(UUID().uuidString).json")
      $0.sidebarStructureAutoRecompute = false
    } operation: {
      let store = TestStore(initialState: state) { RepositoriesFeature() }
      store.exhaustivity = .off
      await body(store)
    }
  }

  @Test(.dependencies) func resolvedRemoteReplacesPlaceholderAndClearsResolving() async {
    let cfg = config()
    let repoID = RepositoriesFeature.remoteRepositoryID(for: cfg)
    await withStore(placeholderState(repoID: repoID, config: cfg)) { store in
      await store.send(
        .remoteRepositoryResolved(
          repositoryID: repoID,
          repository: resolvedRepository(repoID: repoID),
          failureMessage: nil
        )
      )
      await store.finish()
      #expect(store.state.repositories[id: repoID]?.worktrees.isEmpty == false)
      #expect(store.state.resolvingRemoteRepositoryIDs.contains(repoID) == false)
      #expect(store.state.loadFailuresByID[repoID] == nil)
    }
  }

  @Test(.dependencies) func unreachableRemoteRecordsLoadFailureAndKeepsPlaceholder() async {
    let cfg = config()
    let repoID = RepositoriesFeature.remoteRepositoryID(for: cfg)
    await withStore(placeholderState(repoID: repoID, config: cfg)) { store in
      await store.send(
        .remoteRepositoryResolved(
          repositoryID: repoID,
          repository: RepositoriesFeature.remotePlaceholderRepository(config: cfg, repoID: repoID),
          failureMessage: "Can't reach devbox."
        )
      )
      await store.finish()
      #expect(store.state.repositories[id: repoID]?.worktrees.isEmpty == true)
      #expect(store.state.resolvingRemoteRepositoryIDs.contains(repoID) == false)
      #expect(store.state.loadFailuresByID[repoID] == "Can't reach devbox.")
    }
  }

  @Test(.dependencies) func repositoriesLoadedSeedsPlaceholderAndMarksResolving() async {
    let cfg = config()
    let repoID = RepositoriesFeature.remoteRepositoryID(for: cfg)
    var state = RepositoriesFeature.State()
    await withStore(state) { store in
      @Shared(.settingsFile) var settingsFile
      $settingsFile.withLock { $0.global.remoteRepositories = [cfg] }

      await store.send(.repositoriesLoaded([], failures: [], roots: [], animated: false))
      // The remote shows up immediately as a resolving placeholder, before SSH.
      #expect(store.state.repositories[id: repoID]?.worktrees.isEmpty == true)
      #expect(store.state.resolvingRemoteRepositoryIDs.contains(repoID))
      #expect(store.state.loadFailuresByID[repoID] == nil)
      // Drain the background resolution effect (probe fails fast for a fake host).
      await store.finish()
    }
    _ = state
  }

  @Test(.dependencies) func resolvedRemoteIgnoredWhenRepoAbsent() async {
    let cfg = config()
    let repoID = RepositoriesFeature.remoteRepositoryID(for: cfg)
    // The config was removed (or re-keyed) mid-flight: marked resolving, no repo.
    var state = RepositoriesFeature.State()
    state.resolvingRemoteRepositoryIDs = [repoID]
    await withStore(state) { store in
      await store.send(
        .remoteRepositoryResolved(
          repositoryID: repoID,
          repository: resolvedRepository(repoID: repoID),
          failureMessage: nil
        )
      )
      await store.finish()
      // A late result for a gone repo is dropped, but the resolving flag clears.
      #expect(store.state.repositories[id: repoID] == nil)
      #expect(store.state.loadFailuresByID[repoID] == nil)
      #expect(store.state.resolvingRemoteRepositoryIDs.contains(repoID) == false)
    }
  }

  @Test(.dependencies) func reloadReusesResolvedRemoteWithoutRespinning() async {
    let cfg = config()
    let repoID = RepositoriesFeature.remoteRepositoryID(for: cfg)
    var state = RepositoriesFeature.State()
    state.isInitialLoadComplete = true
    state.repositories = [resolvedRepository(repoID: repoID)]
    await withStore(state) { store in
      @Shared(.settingsFile) var settingsFile
      $settingsFile.withLock { $0.global.remoteRepositories = [cfg] }

      await store.send(.repositoriesLoaded([], failures: [], roots: [], animated: false))
      // The already-resolved remote keeps its worktrees and is not re-spun.
      #expect(store.state.repositories[id: repoID]?.worktrees.isEmpty == false)
      #expect(store.state.resolvingRemoteRepositoryIDs.contains(repoID) == false)
      await store.finish()
    }
    _ = state
  }
}
