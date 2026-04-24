import Dependencies
import Foundation

struct ScratchPadScopeState: Equatable, Codable, Sendable {
  var scope: ScratchPadScope
  var tabIDs: [ScratchPadNote.ID]
  var activeTabID: ScratchPadNote.ID?
  var mode: ScratchPadViewMode
}

struct ScratchPadStorageSnapshot: Equatable, Codable, Sendable {
  var notes: [ScratchPadNote]
  var scopes: [ScratchPadScopeState]

  static let empty = ScratchPadStorageSnapshot(notes: [], scopes: [])
}

struct ScratchPadStorageClient: Sendable {
  var loadSnapshot: @Sendable () async throws -> ScratchPadStorageSnapshot?
  var saveSnapshot: @Sendable (ScratchPadStorageSnapshot) async throws -> Void
}

nonisolated enum ScratchPadStorageKey: DependencyKey {
  static let liveValue = ScratchPadStorageClient(
    loadSnapshot: {
      let defaults = UserDefaults.standard
      guard let notesData = defaults.data(forKey: Keys.notes),
        let scopesData = defaults.data(forKey: Keys.scopes)
      else {
        return nil
      }
      let decoder = JSONDecoder()
      return ScratchPadStorageSnapshot(
        notes: try decoder.decode([ScratchPadNote].self, from: notesData),
        scopes: try decoder.decode([ScratchPadScopeState].self, from: scopesData)
      )
    },
    saveSnapshot: { snapshot in
      let defaults = UserDefaults.standard
      let encoder = JSONEncoder()
      defaults.set(try encoder.encode(snapshot.notes), forKey: Keys.notes)
      defaults.set(try encoder.encode(snapshot.scopes), forKey: Keys.scopes)
    }
  )

  static let testValue = ScratchPadStorageClient(
    loadSnapshot: { nil },
    saveSnapshot: { _ in },
  )
}

extension DependencyValues {
  nonisolated var scratchPadStorage: ScratchPadStorageClient {
    get { self[ScratchPadStorageKey.self] }
    set { self[ScratchPadStorageKey.self] = newValue }
  }
}

private nonisolated enum Keys {
  static let notes = "echo-scratch-notes"
  static let scopes = "echo-scratch-tabs"
}
