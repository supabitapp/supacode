import Foundation

enum NotificationTextNormalizer {
  static func normalize(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }

    let lines = trimmed
      .split(whereSeparator: \.isNewline)
      .compactMap { normalizeLine(String($0)) }
      .filter { !$0.isEmpty }

    if !lines.isEmpty {
      return collapseWhitespace(lines.joined(separator: " "))
    }

    return collapseWhitespace(stripInlineMarkdown(trimmed))
  }

  private static func normalizeLine(_ line: String) -> String? {
    var normalized = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return nil }

    if normalized.hasPrefix("```") || normalized.hasPrefix("~~~") {
      return nil
    }

    normalized = normalized.replacing(#/^\s{0,3}#{1,6}\s+/#, with: "")
    normalized = normalized.replacing(#/^\s{0,3}>+\s*/#, with: "")
    normalized = normalized.replacing(#/^\s{0,3}(?:[-+*]|\d+[.)])\s+/#, with: "")
    normalized = normalized.replacing(#/^\[(?: |x|X)\]\s+/#, with: "")

    if let parsed = try? AttributedString(
      markdown: normalized,
      options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    ) {
      normalized = String(parsed.characters)
    } else {
      normalized = stripInlineMarkdown(normalized)
    }

    normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }

  private static func stripInlineMarkdown(_ text: String) -> String {
    text
      .replacing(#/\[([^\]]+)\]\([^)]+\)/#) { String($0.1) }
      .replacing(#/[*_~`]+/#, with: "")
  }

  private static func collapseWhitespace(_ text: String) -> String {
    var collapsed = text.replacing(#/\s+/#, with: " ")
    collapsed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    return collapsed
  }
}
