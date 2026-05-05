import ComposableArchitecture
import Foundation
import IdentifiedCollections
import OrderedCollections
import Testing

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

  // MARK: - helpers.

  private func makeState(repoName: String, customTitle: String?) -> RepositoriesFeature.State {
    let rootURL = URL(fileURLWithPath: "/tmp/\(repoName)")
    let worktree = Worktree(
      id: "/tmp/\(repoName)/main",
      name: "main",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/\(repoName)/main"),
      repositoryRootURL: rootURL
    )
    let repository = Repository(
      id: rootURL.path(percentEncoded: false),
      rootURL: rootURL,
      name: repoName,
      worktrees: IdentifiedArray(uniqueElements: [worktree])
    )
    var state = RepositoriesFeature.State(repositories: [repository])
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
