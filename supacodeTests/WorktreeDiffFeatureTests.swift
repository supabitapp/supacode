import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import supacode

@MainActor
struct WorktreeDiffFeatureTests {
  @Test(.dependencies) func presentingRefreshesEntriesForActiveWorktree() async {
    let clock = TestClock()
    let worktreeID = "/tmp/wt"
    let rootURL = URL(fileURLWithPath: "/tmp/wt")
    let active = WorktreeDiffFeature.ActiveWorktree(id: worktreeID, rootURL: rootURL)
    let entry = GitDiffEntry(path: "File.swift", statusCode: " M", kind: .modified, originalPath: nil)

    let store = TestStore(initialState: WorktreeDiffFeature.State()) {
      WorktreeDiffFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.gitDiffClient = GitDiffClient(
        statusEntries: { _ in [entry] },
        diffText: { _, _ in "" }
      )
    }

    await store.send(.setActiveWorktree(active)) {
      $0.activeWorktree = active
      $0.worktrees[worktreeID] = .init(rootURL: rootURL)
    }

    await store.send(.setPresented(true)) {
      $0.isPresented = true
    }

    await store.receive(\.refreshActiveWorktree) {
      $0.worktrees[worktreeID]?.isLoadingEntries = true
      $0.worktrees[worktreeID]?.entriesError = nil
    }

    await store.receive(\.entriesResponse) {
      $0.worktrees[worktreeID]?.isLoadingEntries = false
      $0.worktrees[worktreeID]?.entries = [entry]
      $0.worktrees[worktreeID]?.entriesError = nil
    }

    await store.send(.setPresented(false)) {
      $0.isPresented = false
    }
  }

  @Test(.dependencies) func selectingEntryLoadsDiff() async {
    let clock = TestClock()
    let worktreeID = "/tmp/wt"
    let rootURL = URL(fileURLWithPath: "/tmp/wt")
    let active = WorktreeDiffFeature.ActiveWorktree(id: worktreeID, rootURL: rootURL)
    let entry = GitDiffEntry(path: "File.swift", statusCode: " M", kind: .modified, originalPath: nil)

    let store = TestStore(initialState: WorktreeDiffFeature.State()) {
      WorktreeDiffFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.gitDiffClient = GitDiffClient(
        statusEntries: { _ in [entry] },
        diffText: { _, _ in "diff --git a/File.swift b/File.swift\n+one\n" }
      )
    }

    await store.send(.setActiveWorktree(active)) {
      $0.activeWorktree = active
      $0.worktrees[worktreeID] = .init(rootURL: rootURL)
    }

    await store.send(.refreshActiveWorktree) {
      $0.worktrees[worktreeID]?.isLoadingEntries = true
      $0.worktrees[worktreeID]?.entriesError = nil
    }

    await store.receive(\.entriesResponse) {
      $0.worktrees[worktreeID]?.isLoadingEntries = false
      $0.worktrees[worktreeID]?.entries = [entry]
      $0.worktrees[worktreeID]?.entriesError = nil
    }

    await store.send(.setSelectedPath(worktreeID, entry.path)) {
      $0.worktrees[worktreeID]?.selectedPath = entry.path
      $0.worktrees[worktreeID]?.diffRequestID = 1
      $0.worktrees[worktreeID]?.diff.isLoading = true
      $0.worktrees[worktreeID]?.diff.error = nil
      $0.worktrees[worktreeID]?.diff.document = .init(revision: 1, text: "")
    }

    await store.receive(\.diffResponse) {
      $0.worktrees[worktreeID]?.diff.isLoading = false
      $0.worktrees[worktreeID]?.diff.error = nil
      $0.worktrees[worktreeID]?.diff.document = .init(revision: 2, text: "diff --git a/File.swift b/File.swift\n+one\n")
    }

    #expect(store.state.worktrees[worktreeID]?.diff.document.text.contains("+one") == true)
  }

  @Test(.dependencies) func staleDiffResponseIsIgnored() async {
    let clock = TestClock()
    let worktreeID = "/tmp/wt"
    let rootURL = URL(fileURLWithPath: "/tmp/wt")
    let active = WorktreeDiffFeature.ActiveWorktree(id: worktreeID, rootURL: rootURL)
    let entry1 = GitDiffEntry(path: "One.swift", statusCode: " M", kind: .modified, originalPath: nil)
    let entry2 = GitDiffEntry(path: "Two.swift", statusCode: " M", kind: .modified, originalPath: nil)

    let store = TestStore(initialState: WorktreeDiffFeature.State()) {
      WorktreeDiffFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.gitDiffClient = GitDiffClient(
        statusEntries: { _ in [entry1, entry2] },
        diffText: { _, entry in
          "diff --git a/\(entry.path) b/\(entry.path)\n"
        }
      )
    }

    await store.send(.setActiveWorktree(active)) {
      $0.activeWorktree = active
      $0.worktrees[worktreeID] = .init(rootURL: rootURL)
    }

    await store.send(.refreshActiveWorktree) {
      $0.worktrees[worktreeID]?.isLoadingEntries = true
      $0.worktrees[worktreeID]?.entriesError = nil
    }

    await store.receive(\.entriesResponse) {
      $0.worktrees[worktreeID]?.isLoadingEntries = false
      $0.worktrees[worktreeID]?.entries = [entry1, entry2]
      $0.worktrees[worktreeID]?.entriesError = nil
    }

    await store.send(.setSelectedPath(worktreeID, entry1.path)) {
      $0.worktrees[worktreeID]?.selectedPath = entry1.path
      $0.worktrees[worktreeID]?.diffRequestID = 1
      $0.worktrees[worktreeID]?.diff.isLoading = true
      $0.worktrees[worktreeID]?.diff.error = nil
      $0.worktrees[worktreeID]?.diff.document = .init(revision: 1, text: "")
    }
    await store.receive(\.diffResponse) {
      $0.worktrees[worktreeID]?.diff.isLoading = false
      $0.worktrees[worktreeID]?.diff.error = nil
      $0.worktrees[worktreeID]?.diff.document = .init(revision: 2, text: "diff --git a/One.swift b/One.swift\n")
    }

    await store.send(.setSelectedPath(worktreeID, entry2.path)) {
      $0.worktrees[worktreeID]?.selectedPath = entry2.path
      $0.worktrees[worktreeID]?.diffRequestID = 2
      $0.worktrees[worktreeID]?.diff.isLoading = true
      $0.worktrees[worktreeID]?.diff.error = nil
      $0.worktrees[worktreeID]?.diff.document = .init(revision: 3, text: "")
    }
    await store.receive(\.diffResponse) {
      $0.worktrees[worktreeID]?.diff.isLoading = false
      $0.worktrees[worktreeID]?.diff.error = nil
      $0.worktrees[worktreeID]?.diff.document = .init(revision: 4, text: "diff --git a/Two.swift b/Two.swift\n")
    }

    #expect(store.state.worktrees[worktreeID]?.selectedPath == entry2.path)
    #expect(store.state.worktrees[worktreeID]?.diff.document.text.contains("Two.swift") == true)

    await store.send(.diffResponse(worktreeID, requestID: 1, .success("stale")))
  }
}
