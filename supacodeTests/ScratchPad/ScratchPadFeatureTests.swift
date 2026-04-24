import ComposableArchitecture
import ConcurrencyExtras
import Foundation
import Testing

@testable import supacode

@MainActor
struct ScratchPadFeatureTests {
  @Test func initialState_hasAtLeastOneTab() {
    let state = ScratchPadFeature.State()

    #expect(state.tabsByScope[.global]?.count == 1)
    #expect(state.activeTabByScope[.global] != nil)
    #expect(state.notesByID.count == 1)
  }

  @Test func createTab_reusesExistingBlankUntitledTab() async {
    let store = TestStore(initialState: ScratchPadFeature.State()) {
      ScratchPadFeature()
    }
    store.exhaustivity = .off

    await store.send(.createTab)

    #expect(store.state.tabsByScope[.global]?.count == 1)
    #expect(store.state.notesByID.count == 1)
  }

  @Test func closeTab_keepsAtLeastOneTabOpen() async {
    let store = TestStore(initialState: ScratchPadFeature.State()) {
      ScratchPadFeature()
    }
    store.exhaustivity = .off

    guard let originalTabID = store.state.activeTabByScope[.global] else {
      Issue.record("Expected seeded tab ID")
      return
    }

    await store.send(.closeTab(originalTabID))

    #expect(store.state.tabsByScope[.global]?.count == 1)
    #expect(store.state.activeTabByScope[.global] != nil)
    #expect(store.state.activeTabByScope[.global] != originalTabID)
    #expect(store.state.notesByID.count == 1)
  }

  @Test func setMode_persistsScopeMode() async {
    let savedSnapshots = LockIsolated<[ScratchPadStorageSnapshot]>([])

    let store = TestStore(initialState: ScratchPadFeature.State()) {
      ScratchPadFeature()
    } withDependencies: {
      $0.scratchPadStorage.saveSnapshot = { snapshot in
        savedSnapshots.withValue { $0.append(snapshot) }
      }
    }

    await store.send(.setMode(.preview)) {
      $0.modeByScope[.global] = .preview
    }

    let snapshots = savedSnapshots.value
    #expect(snapshots.count == 1)
    #expect(snapshots[0].scopes.first?.scope == .global)
    #expect(snapshots[0].scopes.first?.mode == .preview)
  }

  @Test func task_loadsPersistedMode() async {
    let persistedNote = ScratchPadNote(id: "note-1", text: "hello")
    let persistedSnapshot = ScratchPadStorageSnapshot(
      notes: [persistedNote],
      scopes: [
        ScratchPadScopeState(
          scope: .global,
          tabIDs: [persistedNote.id],
          activeTabID: persistedNote.id,
          mode: .split
        )
      ]
    )

    let store = TestStore(initialState: ScratchPadFeature.State()) {
      ScratchPadFeature()
    } withDependencies: {
      $0.scratchPadStorage.loadSnapshot = { persistedSnapshot }
    }

    await store.send(.task)
    await store.receive(.storageLoaded(persistedSnapshot)) {
      $0.notesByID = [persistedNote]
      $0.tabsByScope = [.global: [persistedNote.id]]
      $0.activeTabByScope = [.global: persistedNote.id]
      $0.modeByScope = [.global: .split]
    }

    #expect(store.state.activeMode == .split)
  }
}
