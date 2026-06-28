import AppKit
import SwiftUI

/// The per-(worktree, tab) notes panel: a minimalist rich-text editor with a
/// formatting bar above it. Reads the seed note from `WorktreeNotesManager` and
/// streams edits back through `updateNote` (which autosaves in real time). Mount
/// this keyed `.id(tabID)` so each tab gets a fresh editor + undo stack and a tab
/// switch reloads the correct note.
struct NotesPanelView: View {
  let worktree: Worktree
  let tabID: TerminalTabID
  @Environment(WorktreeNotesManager.self) private var notesManager
  @State private var controller = NoteEditorController()

  var body: some View {
    VStack(spacing: 0) {
      NotesFormatBar(controller: controller)
      Divider()
      RichTextNoteEditor(
        initialContent: seedContent,
        controller: controller,
        onChange: { attributed in
          let document = NoteDocument.make(from: attributed, lastModified: Date())
          notesManager.updateNote(worktreeID: worktree.id, tabID: tabID, document: document)
        }
      )
    }
    .frame(minWidth: 280)
    .background(.background)
  }

  private var seedContent: NSAttributedString {
    notesManager.document(worktreeID: worktree.id, tabID: tabID)?.attributedString()
      ?? NSAttributedString(string: "")
  }
}
