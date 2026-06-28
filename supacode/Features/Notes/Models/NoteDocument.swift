import AppKit
import Foundation
import SupacodeSettingsShared

/// One worktree-tab's note, persisted as RTF `Data` so the full rich-text set
/// (bold/italic/underline/strikethrough, font sizes, inline code, code blocks,
/// bullet/numbered lists) round-trips losslessly. Mirrors the `layouts.json`
/// value pattern: a small Codable struct stored in a per-(worktree, tab) JSON
/// dict, with the heavy formatting kept out of TCA. `Data` JSON-encodes as
/// base64, keeping `notes.json` a single inspectable JSON file.
struct NoteDocument: Codable, Equatable, Sendable {
  /// RTF bytes from `NSAttributedString.rtf(from:documentAttributes:)`.
  var rtf: Data
  var lastModified: Date
}

extension NoteDocument {
  private static let logger = SupaLogger("Notes")

  /// Builds a document from a rich-text value. Returns `nil` when the text is
  /// empty/whitespace-only so the caller drops the key (no-trace emptiness,
  /// matching the layout snapshot's nil semantics).
  static func make(from attributed: NSAttributedString, lastModified: Date) -> NoteDocument? {
    guard !attributed.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
    let range = NSRange(location: 0, length: attributed.length)
    guard let data = attributed.rtf(from: range, documentAttributes: [:]) else {
      Self.logger.warning("Failed to encode note to RTF; dropping edit.")
      return nil
    }
    return NoteDocument(rtf: data, lastModified: lastModified)
  }

  /// Decodes the stored RTF back into a rich-text value. Returns an empty string
  /// when the bytes are unreadable rather than throwing, so a corrupt note never
  /// breaks the editor.
  func attributedString() -> NSAttributedString {
    guard
      let attributed = try? NSAttributedString(
        data: rtf,
        options: [.documentType: NSAttributedString.DocumentType.rtf],
        documentAttributes: nil
      )
    else {
      Self.logger.warning("Failed to decode note RTF; returning empty.")
      return NSAttributedString(string: "")
    }
    return attributed
  }
}
