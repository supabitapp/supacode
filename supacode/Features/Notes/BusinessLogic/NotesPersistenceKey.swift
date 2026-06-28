import Dependencies
import Foundation
import Sharing
import SupacodeSettingsShared

/// In-memory source of truth for per-(worktree, tab) notes, loaded from
/// `notes.json` at launch. Direct clone of `LayoutsKey`: `save()` is a no-op
/// because `NotesIncrementalWriter` is the sole disk writer — persisting here
/// too would race the actor's per-key merge with a whole-dict clobber.
///
/// Shape: `[worktreeID.rawValue: [tabID.uuidString: NoteDocument]]`, matching
/// the `layouts.json` nesting (worktree key -> per-tab payload).
nonisolated struct NotesKeyID: Hashable, Sendable {}

nonisolated struct NotesKey: SharedKey {
  private static let logger = SupaLogger("Notes")

  var id: NotesKeyID { NotesKeyID() }

  func load(
    context _: LoadContext<[String: [String: NoteDocument]]>,
    continuation: LoadContinuation<[String: [String: NoteDocument]]>
  ) {
    @Dependency(\.settingsFileStorage) var storage
    let data: Data
    do {
      data = try storage.load(SupacodePaths.notesURL)
    } catch {
      // File does not exist yet — expected on first run.
      continuation.resumeReturningInitialValue()
      return
    }
    do {
      let notes = try JSONDecoder().decode([String: [String: NoteDocument]].self, from: data)
      continuation.resume(returning: notes)
    } catch {
      Self.logger.warning(
        "Failed to decode notes from \(SupacodePaths.notesURL.path(percentEncoded: false)): \(error)"
      )
      continuation.resumeReturningInitialValue()
    }
  }

  func subscribe(
    context _: LoadContext<[String: [String: NoteDocument]]>,
    subscriber _: SharedSubscriber<[String: [String: NoteDocument]]>
  ) -> SharedSubscription {
    SharedSubscription {}
  }

  func save(
    _: [String: [String: NoteDocument]],
    context _: SaveContext,
    continuation: SaveContinuation
  ) {
    // No-op: `NotesIncrementalWriter` is the sole disk writer for `notes.json`.
    continuation.resume()
  }
}

nonisolated extension SharedReaderKey where Self == NotesKey.Default {
  static var notes: Self {
    Self[NotesKey(), default: [:]]
  }
}
