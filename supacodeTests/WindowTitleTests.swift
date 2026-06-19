import ComposableArchitecture
import Foundation
import IdentifiedCollections
import OrderedCollections
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct WindowTitleTests {
  // MARK: - format.

  @Test func formatsRepoAndTab() {
    #expect(WindowTitle.format(repo: "Acme", tab: "claude") == "Acme · claude")
  }

  @Test func formatsRepoAloneWhenTabIsNil() {
    #expect(WindowTitle.format(repo: "Acme", tab: nil) == "Acme")
  }

  @Test func formatsRepoAloneWhenTabIsEmpty() {
    #expect(WindowTitle.format(repo: "Acme", tab: "") == "Acme")
  }

  // MARK: - sanitize.

  @Test func sanitizeStripsControlBytes() {
    #expect(WindowTitle.sanitize("claude\nsecret") == "claudesecret")
  }

  @Test func sanitizeStripsBellAndEscape() {
    #expect(WindowTitle.sanitize("foo\u{1B}\u{07}bar") == "foobar")
  }

  @Test func sanitizeReturnsNilWhenAllControlOrWhitespace() {
    #expect(WindowTitle.sanitize("\n\t\u{07}") == nil)
    #expect(WindowTitle.sanitize("   ") == nil)
    #expect(WindowTitle.sanitize("") == nil)
  }

  @Test func sanitizePreservesNormalText() {
    #expect(WindowTitle.sanitize("claude code") == "claude code")
  }

  // MARK: - compute.

  @Test func computeReturnsAppNameWhenNoSelection() {
    let state = RepositoriesFeature.State()
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    #expect(WindowTitle.compute(repositories: state, terminalManager: manager) == "Supacode")
  }

  @Test func computeReturnsArchiveLabelForArchivedSelection() {
    var state = RepositoriesFeature.State()
    state.selection = .archivedWorktrees
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    #expect(WindowTitle.compute(repositories: state, terminalManager: manager) == "Archive")
  }

  @Test func computeFallsBackToAppNameForUnknownWorktreeID() {
    var state = RepositoriesFeature.State()
    state.selection = .worktree("does-not-exist")
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    #expect(WindowTitle.compute(repositories: state, terminalManager: manager) == "Supacode")
  }

  @Test func computeUsesRepositoryNameWhenNoCustomTitle() {
    let state = makeState(repoName: "acme-app", customTitle: nil)
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    #expect(WindowTitle.compute(repositories: state, terminalManager: manager) == "acme-app")
  }

  @Test func computePrefersCustomTitleOverRepositoryName() {
    let state = makeState(repoName: "acme-app", customTitle: "Acme")
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    #expect(WindowTitle.compute(repositories: state, terminalManager: manager) == "Acme")
  }

  @Test func computeIgnoresWhitespaceOnlyCustomTitle() {
    let state = makeState(repoName: "acme-app", customTitle: "   ")
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    #expect(WindowTitle.compute(repositories: state, terminalManager: manager) == "acme-app")
  }

  @Test func computeFailedRepositoryUsesDirectoryName() {
    var state = RepositoriesFeature.State()
    let id: Repository.ID = "/tmp/missing-repo"
    state.repositoryRoots = [URL(fileURLWithPath: id.rawValue)]
    state.loadFailuresByID = [id: "Not found"]
    state.selection = .failedRepository(id)
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    #expect(WindowTitle.compute(repositories: state, terminalManager: manager) == "missing-repo · Unavailable")
  }

  @Test func computeFailedRepositoryPrefersCustomTitle() {
    var state = RepositoriesFeature.State()
    let id: Repository.ID = "/tmp/missing-repo"
    state.repositoryRoots = [URL(fileURLWithPath: id.rawValue)]
    state.loadFailuresByID = [id: "Not found"]
    state.selection = .failedRepository(id)
    state.$sidebar.withLock { sidebar in
      var section = sidebar.sections[id] ?? SidebarState.Section()
      section.title = "My Project"
      sidebar.sections[id] = section
    }
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    #expect(WindowTitle.compute(repositories: state, terminalManager: manager) == "My Project · Unavailable")
  }

  @Test func computeFailedRemoteRepositoryUsesPlaceholderNameNotFileURL() {
    let config = RemoteRepositoryConfig(
      host: RemoteHost(alias: "devbox"),
      remotePath: "/home/me/proj",
      displayName: "proj"
    )
    let id = RepositoriesFeature.remoteRepositoryID(for: config)
    // A disconnected remote keeps a placeholder repository plus a load failure.
    let placeholder = Repository(
      id: id,
      rootURL: URL(fileURLWithPath: config.normalizedRemotePath),
      name: config.resolvedDisplayName,
      worktrees: [],
      isGitRepository: true,
      host: config.host
    )
    var state = RepositoriesFeature.State()
    state.repositories = [placeholder]
    state.loadFailuresByID = [id: "Can't reach devbox."]
    state.selection = .failedRepository(id)
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    // Deriving from the `remote://` id as a file URL would mangle the name.
    #expect(WindowTitle.compute(repositories: state, terminalManager: manager) == "proj · Unavailable")
  }

  // MARK: - helpers.

  private func makeState(repoName: String, customTitle: String?) -> RepositoriesFeature.State {
    let rootURL = URL(fileURLWithPath: "/tmp/\(repoName)")
    let worktree = Worktree(
      id: WorktreeID("/tmp/\(repoName)/main"),
      name: "main",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/\(repoName)/main"),
      repositoryRootURL: rootURL
    )
    let repository = Repository(
      id: RepositoryID(rootURL.path(percentEncoded: false)),
      rootURL: rootURL,
      name: repoName,
      worktrees: IdentifiedArray(uniqueElements: [worktree])
    )
    var state = RepositoriesFeature.State(reconciledRepositories: [repository])
    state.selection = .worktree(worktree.id)
    if let customTitle {
      state.$sidebar.withLock { sidebar in
        var section = sidebar.sections[repository.id] ?? SidebarState.Section()
        section.title = customTitle
        sidebar.sections[repository.id] = section
      }
    }
    return state
  }
}
