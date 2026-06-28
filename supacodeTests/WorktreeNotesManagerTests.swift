import Dependencies
import Foundation
import Sharing
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct WorktreeNotesManagerTests {
  private func note() -> NoteDocument {
    NoteDocument(rtf: Data("x".utf8), lastModified: Date(timeIntervalSince1970: 0))
  }

  /// Rapid edits don't touch disk until a flush: with a `TestClock` that is never
  /// advanced the debounce never fires, so the only write is the synchronous
  /// on-quit `flushAllSync` — proving per-keystroke writes are coalesced. Also
  /// covers the synchronous in-memory update and the empty-note delete semantics.
  @Test func editsCoalesceAndFlushAllSyncPersistsOnce() {
    let inner = SettingsFileStorage.inMemory()
    let saveCount = LockIsolated(0)
    let storage = SettingsFileStorage(
      load: { try inner.load($0) },
      save: { data, url in
        if url == SupacodePaths.notesURL { saveCount.withValue { $0 += 1 } }
        try inner.save(data, url)
      }
    )

    withDependencies {
      $0.settingsFileStorage = storage
    } operation: {
      @Shared(.notes) var notes
      $notes.withLock { $0 = [:] }

      let manager = WorktreeNotesManager(clock: TestClock())
      let worktreeID: Worktree.ID = "/tmp/repo"
      let tabID = TerminalTabID(rawValue: UUID())

      manager.updateNote(worktreeID: worktreeID, tabID: tabID, document: note())
      manager.updateNote(worktreeID: worktreeID, tabID: tabID, document: note())
      manager.updateNote(worktreeID: worktreeID, tabID: tabID, document: note())

      // The in-memory update is synchronous so an on-quit flush sees the latest edit.
      #expect(manager.document(worktreeID: worktreeID, tabID: tabID) != nil)
      // No debounced disk write yet — the TestClock was never advanced.
      #expect(saveCount.value == 0)

      manager.flushAllSync()
      #expect(saveCount.value == 1)

      // Clearing the note drops the key with no trace.
      manager.updateNote(worktreeID: worktreeID, tabID: tabID, document: nil)
      #expect(manager.document(worktreeID: worktreeID, tabID: tabID) == nil)
    }
  }
}
