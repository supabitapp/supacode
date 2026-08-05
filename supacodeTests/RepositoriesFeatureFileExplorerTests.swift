import Clocks
import ComposableArchitecture
import Foundation
import IdentifiedCollections
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

/// The post-reduce reconcile hook is the only wiring between the inspector
/// pane and `FileExplorerFeature`; these tests pin that it forwards context
/// exactly on change and never re-sends (a broken equality guard would loop).
@MainActor
struct RepositoriesFeatureFileExplorerTests {
  private nonisolated static func makeWorktree(path: String) -> Worktree {
    Worktree(
      location: .local(
        workingDirectory: URL(filePath: path, directoryHint: .isDirectory),
        repositoryRoot: URL(filePath: path, directoryHint: .isDirectory)
      ),
      kind: .git,
      name: (path as NSString).lastPathComponent,
      detail: "main"
    )
  }

  private func makeState(worktrees: [Worktree]) -> RepositoriesFeature.State {
    var state = RepositoriesFeature.State()
    state.repositories = IdentifiedArray(
      uniqueElements: worktrees.map { worktree in
        Repository(
          location: .local(worktree.repositoryRootURL),
          kind: .git,
          name: worktree.name,
          worktrees: [worktree]
        )
      }
    )
    return state
  }

  @Test func togglingFilesPaneForwardsContextExactlyOnce() async {
    let worktree = Self.makeWorktree(path: "/tmp/repo-a")
    var initialState = makeState(worktrees: [worktree])
    initialState.selection = .worktree(worktree.id)
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.sidebarStructureAutoRecompute = false
      $0.continuousClock = TestClock()
    }

    await store.send(.toggleInspectorPane(.files)) {
      $0.inspectorPresented = true
      $0.inspectorPane = .files
    }
    // Exactly one forward; a second would fail the exhaustive store.
    await store.receive(\.fileExplorer.contextChanged) {
      $0.fileExplorer.isVisible = true
      $0.fileExplorer.context = FileExplorerFeature.Context(worktree: worktree)
      $0.fileExplorer.trees[worktree.id] = FileExplorerFeature.TreeState(
        root: worktree.localWorkingDirectory!,
        directories: [
          "": FileExplorerFeature.DirectoryNode(
            status: .loading(previous: nil),
            requestedLimit: FileExplorerFeature.initialListingLimit
          )
        ]
      )
      $0.fileExplorer.recentWorktreeIDs = [worktree.id]
    }
    await store.receive(\.fileExplorer.listingLoaded) {
      $0.fileExplorer.trees[worktree.id]?.directories[""]?.status = .loaded(
        FileExplorerListing(entries: [], totalCount: 0, modificationDate: nil)
      )
    }

    // An unrelated action while the pane is open must not re-forward context.
    await store.send(.dismissToast)

    // Closing the pane forwards hidden exactly once.
    await store.send(.toggleInspectorPane(.files)) {
      $0.inspectorPresented = false
    }
    await store.receive(\.fileExplorer.contextChanged) {
      $0.fileExplorer.isVisible = false
    }
  }

  @Test func selectionChangeWhileOpenRetargetsTheExplorer() async {
    let worktreeA = Self.makeWorktree(path: "/tmp/repo-a")
    let worktreeB = Self.makeWorktree(path: "/tmp/repo-b")
    var initialState = makeState(worktrees: [worktreeA, worktreeB])
    initialState.selection = .worktree(worktreeA.id)
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.sidebarStructureAutoRecompute = false
      $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off

    await store.send(.toggleInspectorPane(.files))
    await store.receive(\.fileExplorer.contextChanged)

    await store.send(.selectWorktree(worktreeB.id))
    await store.receive(\.fileExplorer.contextChanged) {
      $0.fileExplorer.context = FileExplorerFeature.Context(worktree: worktreeB)
    }
    await store.skipReceivedActions()
    #expect(store.state.fileExplorer.activeWorktreeID == worktreeB.id)

    await store.send(.toggleInspectorPane(.files))
    await store.receive(\.fileExplorer.contextChanged)
  }

  @Test func paneClosedMeansNoForwardingAtAll() async {
    let worktree = Self.makeWorktree(path: "/tmp/repo-a")
    var initialState = makeState(worktrees: [worktree])
    initialState.selection = .worktree(worktree.id)
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.sidebarStructureAutoRecompute = false
      $0.continuousClock = TestClock()
    }

    // With the pane closed the hook must stay silent for pane-unrelated
    // actions; the exhaustive store fails on any stray forward.
    await store.send(.dismissToast)
    await store.send(.toggleInspectorPane(.git)) {
      $0.inspectorPresented = true
      $0.inspectorPane = .git
    }
  }
}
