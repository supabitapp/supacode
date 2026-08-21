import Foundation

/// Merges the layered `supaignore` sources (global, repo default, per-repo
/// committed) into one gitignore-syntax blob for `git ls-files --exclude-from`.
/// Ordered least to most specific so the committed file's patterns and
/// negations win last.
public nonisolated enum SupaignoreMerge {
  /// Filename resolved at each level, alongside `supacode.json`.
  public static let fileName = "supaignore"

  /// Joins present sources with an explicit newline so a source missing its
  /// trailing newline can't fuse into the next level's first pattern. Returns
  /// `nil` when no effective (non-blank, non-comment) pattern exists, so the
  /// caller keeps the unfiltered `wt` copy path.
  public static func merged(global: String?, repoDefault: String?, committed: String?) -> String? {
    var blocks: [String] = []
    for source in [global, repoDefault, committed] {
      guard let source else { continue }
      // Detect a blank source with a trimmed view, but emit the original bytes
      // so significant pattern whitespace (e.g. a trailing `\ `) survives.
      guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
      blocks.append(strippingTrailingNewlines(source))
    }
    guard !blocks.isEmpty else { return nil }
    let text = blocks.joined(separator: "\n") + "\n"
    guard hasEffectivePattern(in: text) else { return nil }
    return text
  }

  private static func strippingTrailingNewlines(_ source: String) -> String {
    var result = source
    while result.last == "\n" || result.last == "\r" {
      result.removeLast()
    }
    return result
  }

  /// Whether `text` holds at least one effective pattern (a non-blank line whose
  /// first column is not `#`), i.e. a filter that actually excludes something.
  public static func hasEffectivePattern(in text: String) -> Bool {
    for line in text.split(whereSeparator: \.isNewline) {
      // Trailing whitespace is insignificant in gitignore, but leading
      // whitespace is part of the pattern and `#` starts a comment only at
      // column 0, so a leading space makes it a real pattern.
      guard line.contains(where: { !$0.isWhitespace }), line.first != "#" else { continue }
      return true
    }
    return false
  }
}
