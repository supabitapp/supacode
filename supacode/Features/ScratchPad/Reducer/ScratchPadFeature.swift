import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

private nonisolated let scratchPadLogger = SupaLogger("ScratchPad")

@MainActor
@Reducer
struct ScratchPadFeature {
  @ObservableState
  struct State: Equatable {
    var notesByID: IdentifiedArrayOf<ScratchPadNote>
    var tabsByScope: [ScratchPadScope: [ScratchPadNote.ID]]
    var activeTabByScope: [ScratchPadScope: ScratchPadNote.ID]
    var modeByScope: [ScratchPadScope: ScratchPadViewMode]
    var currentScope: ScratchPadScope

    init(currentScope: ScratchPadScope = .global) {
      self.notesByID = []
      self.tabsByScope = [:]
      self.activeTabByScope = [:]
      self.modeByScope = [:]
      self.currentScope = currentScope
      ensureTabInvariants(for: currentScope)
    }

    var activeTabID: ScratchPadNote.ID? {
      activeTabByScope[currentScope]
    }

    var activeMode: ScratchPadViewMode {
      modeByScope[currentScope, default: .edit]
    }

    mutating func apply(_ snapshot: ScratchPadStorageSnapshot) {
      notesByID = IdentifiedArray(uniqueElements: snapshot.notes)
      tabsByScope = Dictionary(uniqueKeysWithValues: snapshot.scopes.map { ($0.scope, $0.tabIDs) })
      activeTabByScope = Dictionary(
        uniqueKeysWithValues: snapshot.scopes.compactMap { scopeState in
          guard let activeTabID = scopeState.activeTabID else {
            return nil
          }
          return (scopeState.scope, activeTabID)
        }
      )
      modeByScope = Dictionary(uniqueKeysWithValues: snapshot.scopes.map { ($0.scope, $0.mode) })

      ensureTabInvariants(for: currentScope)
    }

    mutating func ensureTabInvariants(for scope: ScratchPadScope) {
      var tabIDs = tabsByScope[scope] ?? []

      tabIDs.removeAll { notesByID[id: $0] == nil }

      if tabIDs.isEmpty {
        let note = ScratchPadNote()
        notesByID.append(note)
        tabIDs = [note.id]
      }

      tabsByScope[scope] = tabIDs

      if let activeTabID = activeTabByScope[scope], tabIDs.contains(activeTabID) {
        // keep current active tab.
      } else {
        activeTabByScope[scope] = tabIDs.first
      }

      modeByScope[scope, default: .edit] = modeByScope[scope, default: .edit]
    }

    mutating func removeNoteIfUnused(_ noteID: ScratchPadNote.ID) {
      let isUsed = tabsByScope.values.contains { $0.contains(noteID) }
      guard !isUsed else { return }
      notesByID.remove(id: noteID)
    }

    func snapshot() -> ScratchPadStorageSnapshot {
      let scopeStates = tabsByScope
        .sorted { lhs, rhs in lhs.key.sortKey < rhs.key.sortKey }
        .map { scope, tabIDs in
          ScratchPadScopeState(
            scope: scope,
            tabIDs: tabIDs,
            activeTabID: activeTabByScope[scope],
            mode: modeByScope[scope, default: .edit]
          )
        }

      return ScratchPadStorageSnapshot(notes: Array(notesByID), scopes: scopeStates)
    }
  }

  enum Action: Equatable {
    case task
    case storageLoaded(ScratchPadStorageSnapshot?)
    case storageFailed(String)

    case setScope(ScratchPadScope)
    case createTab
    case selectTab(ScratchPadNote.ID)
    case closeTab(ScratchPadNote.ID)
    case setMode(ScratchPadViewMode)
  }

  @Dependency(\.scratchPadStorage) private var storage

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .task:
        return .run { send in
          do {
            let snapshot = try await storage.loadSnapshot()
            await send(.storageLoaded(snapshot))
          } catch {
            await send(.storageFailed(error.localizedDescription))
          }
        }

      case .storageLoaded(let snapshot):
        guard let snapshot else {
          return .none
        }
        state.apply(snapshot)
        return .none

      case .storageFailed(let message):
        scratchPadLogger.warning("Scratch Pad load failed: \(message)")
        return .none

      case .setScope(let scope):
        state.currentScope = scope
        state.ensureTabInvariants(for: scope)
        return persist(state)

      case .createTab:
        let scope = state.currentScope
        state.ensureTabInvariants(for: scope)

        if let existingBlankID = state.tabsByScope[scope]?.first(where: { tabID in
          state.notesByID[id: tabID]?.isBlankUntitled == true
        }) {
          state.activeTabByScope[scope] = existingBlankID
          return persist(state)
        }

        let note = ScratchPadNote()
        state.notesByID.append(note)
        state.tabsByScope[scope, default: []].append(note.id)
        state.activeTabByScope[scope] = note.id
        state.ensureTabInvariants(for: scope)
        return persist(state)

      case .selectTab(let noteID):
        let scope = state.currentScope
        guard state.tabsByScope[scope, default: []].contains(noteID) else {
          return .none
        }
        state.activeTabByScope[scope] = noteID
        return persist(state)

      case .closeTab(let noteID):
        let scope = state.currentScope
        guard var tabIDs = state.tabsByScope[scope],
          tabIDs.contains(noteID)
        else {
          return .none
        }

        tabIDs.removeAll { $0 == noteID }
        state.tabsByScope[scope] = tabIDs

        if state.activeTabByScope[scope] == noteID {
          state.activeTabByScope[scope] = tabIDs.last
        }

        state.removeNoteIfUnused(noteID)
        state.ensureTabInvariants(for: scope)
        return persist(state)

      case .setMode(let mode):
        state.modeByScope[state.currentScope] = mode
        return persist(state)
      }
    }
  }

  private func persist(_ state: State) -> Effect<Action> {
    let snapshot = state.snapshot()
    return .run { _ in
      do {
        try await storage.saveSnapshot(snapshot)
      } catch {
        scratchPadLogger.warning("Scratch Pad save failed: \(error.localizedDescription)")
      }
    }
  }
}

private extension ScratchPadScope {
  var sortKey: String {
    switch self {
    case .global:
      return "0:global"
    case .worktree(let id):
      return "1:\(id)"
    }
  }
}
