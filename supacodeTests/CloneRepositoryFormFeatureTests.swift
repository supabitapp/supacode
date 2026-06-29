import ComposableArchitecture
import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct CloneRepositoryFormFeatureTests {
  @Test func canSubmitRequiresUrlAndLocationAndResolvesDestination() {
    var state = CloneRepositoryFormFeature.State()
    #expect(!state.canSubmit)
    state.repositoryURL = "https://github.com/org/repo.git"
    #expect(!state.canSubmit)
    state.cloneLocationPath = "/tmp/dest"
    #expect(state.canSubmit)
    #expect(state.effectiveFolderName == "repo")
    #expect(state.destinationURL?.path(percentEncoded: false) == "/tmp/dest/repo")
  }

  @Test func folderNameOverridesDerivedName() {
    var state = CloneRepositoryFormFeature.State(
      repositoryURL: "https://github.com/org/repo.git",
      cloneLocationPath: "/tmp/dest"
    )
    state.folderName = "custom"
    #expect(state.effectiveFolderName == "custom")
    #expect(state.destinationURL?.lastPathComponent == "custom")
  }

  @Test func invalidDepthBlocksSubmitWithMessage() {
    var state = CloneRepositoryFormFeature.State(
      repositoryURL: "https://github.com/org/repo.git",
      cloneLocationPath: "/tmp/dest"
    )
    state.depth = "0"
    #expect(!state.canSubmit)
    #expect(state.depthValidationMessage == "Depth must be a positive whole number.")
    state.depth = "abc"
    #expect(!state.canSubmit)
    state.depth = "5"
    #expect(state.canSubmit)
    #expect(state.depthValidationMessage == nil)
    #expect(state.parsedDepth == 5)
  }

  @Test func compactProgressLineKeepsPhaseThroughPercentage() {
    var state = CloneRepositoryFormFeature.State()
    #expect(state.compactProgressLine == nil)
    state.progressLine = "Receiving objects: 47% (470/1000), 1.20 MiB | 2.40 MiB/s"
    #expect(state.compactProgressLine == "Receiving objects: 47%")
    state.progressLine = "remote: Compressing objects: 100% (50/50), done."
    #expect(state.compactProgressLine == "remote: Compressing objects: 100%")
    // No percentage: fall back to the whole line (the view truncates + hover).
    state.progressLine = "Cloning into 'repo'..."
    #expect(state.compactProgressLine == "Cloning into 'repo'...")
  }

  @Test func locationSelectedSetsPath() async {
    let store = TestStore(initialState: CloneRepositoryFormFeature.State()) {
      CloneRepositoryFormFeature()
    }
    await store.send(.locationSelected(URL(fileURLWithPath: "/tmp/code"))) {
      $0.cloneLocationPath = "/tmp/code"
    }
  }

  @Test func bindingClearsStaleValidationMessage() async {
    var initial = CloneRepositoryFormFeature.State(repositoryURL: "x")
    initial.cloneFailureMessage = "stale"
    let store = TestStore(initialState: initial) { CloneRepositoryFormFeature() }
    await store.send(.binding(.set(\.repositoryURL, "y"))) {
      $0.repositoryURL = "y"
      $0.cloneFailureMessage = nil
    }
  }

  @Test func successfulCloneStreamsProgressThenDelegatesDirectory() async {
    let store = TestStore(
      initialState: CloneRepositoryFormFeature.State(
        repositoryURL: "https://github.com/org/repo.git",
        cloneLocationPath: "/tmp/dest"
      )
    ) {
      CloneRepositoryFormFeature()
    } withDependencies: {
      $0.gitClient.cloneStream = { _, destination, _, _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.outputLine(ShellStreamLine(source: .stderr, text: "Receiving objects: 100%")))
          continuation.yield(.finished(directory: destination))
          continuation.finish()
        }
      }
    }
    await store.send(.submitButtonTapped) {
      $0.isCloning = true
    }
    await store.receive(\.cloneProgress) {
      $0.progressLine = "Receiving objects: 100%"
    }
    await store.receive(\.cloneSucceeded)
    await store.receive(\.delegate)
  }

  @Test func failedCloneShowsFooterAndKeepsSheetOpen() async {
    let failure = GitClientError.commandFailed(command: "git clone", message: "not found")
    let store = TestStore(
      initialState: CloneRepositoryFormFeature.State(
        repositoryURL: "https://github.com/org/missing.git",
        cloneLocationPath: "/tmp/dest"
      )
    ) {
      CloneRepositoryFormFeature()
    } withDependencies: {
      $0.gitClient.cloneStream = { _, _, _, _ in
        AsyncThrowingStream { $0.finish(throwing: failure) }
      }
    }
    await store.send(.submitButtonTapped) {
      $0.isCloning = true
    }
    await store.receive(\.cloneFailed) {
      $0.isCloning = false
      $0.cloneFailureMessage = failure.localizedDescription
    }
  }

  @Test func emptyOutputCloneShowsFailureAndResetsState() async {
    let store = TestStore(
      initialState: CloneRepositoryFormFeature.State(
        repositoryURL: "https://github.com/org/repo.git",
        cloneLocationPath: "/tmp/dest"
      )
    ) {
      CloneRepositoryFormFeature()
    } withDependencies: {
      $0.gitClient.cloneStream = { _, _, _, _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.outputLine(ShellStreamLine(source: .stderr, text: "Cloning…")))
          continuation.finish()
        }
      }
    }
    await store.send(.submitButtonTapped) {
      $0.isCloning = true
    }
    await store.receive(\.cloneProgress) {
      $0.progressLine = "Cloning…"
    }
    await store.receive(\.cloneFailed) {
      $0.isCloning = false
      $0.progressLine = nil
      $0.cloneFailureMessage = "Clone produced no output."
    }
  }

  @Test func cancelDelegatesCancel() async {
    let store = TestStore(initialState: CloneRepositoryFormFeature.State()) {
      CloneRepositoryFormFeature()
    }
    await store.send(.cancelButtonTapped)
    await store.receive(\.delegate)
  }
}

@MainActor
struct CloneRepositoryParentWiringTests {
  @Test func requestCloneRepositoryPresentsFormAndCancelDismisses() async {
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.sidebarStructureAutoRecompute = false
    }
    store.exhaustivity = .off

    await store.send(.requestCloneRepository)
    #expect(store.state.cloneRepositoryForm != nil)
    await store.send(.cloneRepositoryForm(.presented(.delegate(.cancel))))
    #expect(store.state.cloneRepositoryForm == nil)
  }

  @Test func clonedDelegateDismissesAndOpensClonedDirectory() async {
    let directory = URL(fileURLWithPath: "/tmp/dest/repo")
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.sidebarStructureAutoRecompute = false
      $0.repositoryPersistence.loadRoots = { [] }
      $0.repositoryPersistence.saveRoots = { _ in }
      $0.gitClient.repoRoot = { $0 }
      $0.gitClient.worktrees = { _ in [] }
    }
    store.exhaustivity = .off

    await store.send(.requestCloneRepository)
    await store.send(.cloneRepositoryForm(.presented(.delegate(.cloned(directory)))))
    #expect(store.state.cloneRepositoryForm == nil)
    await store.receive(\.openRepositories)
    await store.finish()
  }

  @Test func seedsLocationFromLastUsedAndPersistsParentOnClone() async {
    let suiteName = "clone-seed-\(UUID().uuidString)"
    let suite = UserDefaults(suiteName: suiteName)!
    suite.set("/tmp/known", forKey: "lastCloneLocationPath")
    defer { suite.removePersistentDomain(forName: suiteName) }
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.sidebarStructureAutoRecompute = false
      $0.defaultAppStorage = suite
      $0.repositoryPersistence.loadRoots = { [] }
      $0.repositoryPersistence.saveRoots = { _ in }
      $0.gitClient.repoRoot = { $0 }
      $0.gitClient.worktrees = { _ in [] }
    }
    store.exhaustivity = .off

    await store.send(.requestCloneRepository)
    #expect(store.state.cloneRepositoryForm?.cloneLocationPath == "/tmp/known")
    await store.send(.cloneRepositoryForm(.presented(.delegate(.cloned(URL(fileURLWithPath: "/tmp/dest/repo"))))))
    await store.receive(\.openRepositories)
    await store.finish()
    #expect(suite.string(forKey: "lastCloneLocationPath") == "/tmp/dest")
  }

  @Test func seedsHomeWhenNoLastUsedLocation() async {
    let suiteName = "clone-seed-empty-\(UUID().uuidString)"
    let suite = UserDefaults(suiteName: suiteName)!
    defer { suite.removePersistentDomain(forName: suiteName) }
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.sidebarStructureAutoRecompute = false
      $0.defaultAppStorage = suite
    }
    store.exhaustivity = .off

    await store.send(.requestCloneRepository)
    #expect(
      store.state.cloneRepositoryForm?.cloneLocationPath
        == FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
    )
  }
}
