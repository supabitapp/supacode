import AppKit
import Foundation

nonisolated enum DiffSyntaxHighlighter {
  nonisolated static func highlight(diffText: String, appearance: NSAppearance?) -> NSAttributedString {
    let isDark = appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    let baseAttributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: NSColor.labelColor,
    ]

    let result = NSMutableAttributedString()
    let lines = diffText.split(separator: "\n", omittingEmptySubsequences: false)
    for (index, line) in lines.enumerated() {
      let lineStr = String(line)
      var attributes = baseAttributes
      if lineStr.hasPrefix("+++") || lineStr.hasPrefix("---") {
        attributes[.foregroundColor] = NSColor.labelColor
        attributes[.font] = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .bold)
      } else if lineStr.hasPrefix("@@") {
        attributes[.foregroundColor] = NSColor.secondaryLabelColor
      } else if lineStr.hasPrefix("diff ") {
        attributes[.foregroundColor] = NSColor.labelColor
        attributes[.font] = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .bold)
      } else if lineStr.hasPrefix("+") {
        attributes[.foregroundColor] = NSColor.systemGreen
        attributes[.backgroundColor] = NSColor.systemGreen.withAlphaComponent(isDark ? 0.15 : 0.1)
      } else if lineStr.hasPrefix("-") {
        attributes[.foregroundColor] = NSColor.systemRed
        attributes[.backgroundColor] = NSColor.systemRed.withAlphaComponent(isDark ? 0.15 : 0.1)
      }
      result.append(NSAttributedString(string: lineStr, attributes: attributes))
      if index < lines.count - 1 {
        result.append(NSAttributedString(string: "\n", attributes: baseAttributes))
      }
    }
    return result
  }
}
