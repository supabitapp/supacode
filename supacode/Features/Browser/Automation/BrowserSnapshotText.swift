import Foundation

nonisolated enum BrowserSnapshotText {
  struct Line: Equatable, Sendable {
    var indent: Int
    var content: String
    var role: String?
    var ref: String?
    var hasPointerCursor = false

    var rendered: String { String(repeating: " ", count: indent) + "- " + content }
  }

  static let interactiveRoles: Set<String> = [
    "button", "checkbox", "combobox", "link", "listbox", "menuitem", "menuitemcheckbox", "menuitemradio",
    "option", "radio", "searchbox", "slider", "spinbutton", "switch", "tab", "textbox", "treeitem",
  ]

  static func parse(_ text: String) -> [Line] {
    text.split(separator: "\n", omittingEmptySubsequences: true).map { rawLine in
      let indent = rawLine.prefix(while: { $0 == " " }).count
      var content = rawLine.dropFirst(indent)
      if content.hasPrefix("- ") {
        content = content.dropFirst(2)
      }
      let identity = identity(of: content)
      return Line(
        indent: indent,
        content: String(content),
        role: identity.role,
        ref: identity.ref,
        hasPointerCursor: identity.hasPointerCursor
      )
    }
  }

  static func render(_ lines: [Line]) -> String {
    lines.map(\.rendered).joined(separator: "\n")
  }

  static func interactive(_ text: String) -> String {
    struct Enclosing {
      var indent: Int
      var hasRef: Bool
      var keptIndent: Int?
    }
    var kept: [Line] = []
    var enclosing: [Enclosing] = []
    for line in parse(text) {
      enclosing.removeAll { $0.indent >= line.indent }
      var keptLine = line
      if line.ref == nil {
        let owner = enclosing.last(where: \.hasRef)
        if let owner, let ownerIndent = owner.keptIndent, !line.content.hasPrefix("/url:") {
          keptLine.indent = ownerIndent + line.indent - owner.indent
          kept.append(keptLine)
        }
        enclosing.append(Enclosing(indent: line.indent, hasRef: false, keptIndent: nil))
        continue
      }
      guard line.role.map(interactiveRoles.contains) == true || line.hasPointerCursor else {
        enclosing.append(Enclosing(indent: line.indent, hasRef: true, keptIndent: nil))
        continue
      }
      keptLine.indent = enclosing.last(where: { $0.keptIndent != nil })?.keptIndent.map { $0 + 2 } ?? 0
      kept.append(keptLine)
      enclosing.append(Enclosing(indent: line.indent, hasRef: true, keptIndent: keptLine.indent))
    }
    return render(closingChildlessKeys(kept))
  }

  static func scoped(_ text: String, to ref: String) -> String? {
    let lines = parse(text)
    guard let start = lines.firstIndex(where: { $0.ref == ref }) else { return nil }
    let base = lines[start].indent
    let end = lines[(start + 1)...].firstIndex(where: { $0.indent <= base }) ?? lines.count
    return render(
      lines[start..<end].map { line in
        var shifted = line
        shifted.indent -= base
        return shifted
      })
  }

  static func capped(_ text: String, maxBytes: Int, hint: String) -> String {
    guard text.utf8.count > maxBytes else { return text }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    var keptCount = 0
    var bytes = 0
    for line in lines {
      let cost = line.utf8.count + 1
      guard bytes + cost <= maxBytes else { break }
      bytes += cost
      keptCount += 1
    }
    let notice = "... \(lines.count - keptCount) more lines not shown. \(hint)"
    return (lines.prefix(keptCount).map(String.init) + [notice]).joined(separator: "\n")
  }

  private static func closingChildlessKeys(_ lines: [Line]) -> [Line] {
    lines.enumerated().map { index, line in
      let hasChildren = index + 1 < lines.count && lines[index + 1].indent > line.indent
      guard !hasChildren else { return line }
      var closed = line
      closed.content = closingKey(line.content)
      return closed
    }
  }

  static func closingKey(_ content: String) -> String {
    content.hasSuffix("]:") || content.hasSuffix("]':") ? String(content.dropLast()) : content
  }

  private struct Identity {
    var role: String?
    var ref: String?
    var hasPointerCursor = false
  }

  private static func identity(of content: Substring) -> Identity {
    var rest = content
    if rest.first == "'" {
      rest = rest.dropFirst()
    }
    let role = rest.prefix(while: { $0.isASCII && $0.isLowercase })
    guard !role.isEmpty else { return Identity() }
    var identity = Identity(role: String(role))
    rest = rest.dropFirst(role.count)
    if rest.hasPrefix(" \"") {
      guard let afterName = endOfQuotedName(in: rest.dropFirst(2)) else { return identity }
      rest = rest[afterName...]
    }
    while rest.hasPrefix(" ["), let close = rest.firstIndex(of: "]") {
      let attribute = rest[rest.index(rest.startIndex, offsetBy: 2)..<close]
      if attribute.hasPrefix("ref=") {
        identity.ref = String(attribute.dropFirst(4))
      } else if attribute == "cursor=pointer" {
        identity.hasPointerCursor = true
      }
      rest = rest[rest.index(after: close)...]
    }
    return identity
  }

  private static func endOfQuotedName(in text: Substring) -> Substring.Index? {
    var isEscaped = false
    for index in text.indices {
      if isEscaped {
        isEscaped = false
      } else if text[index] == "\\" {
        isEscaped = true
      } else if text[index] == "\"" {
        return text.index(after: index)
      }
    }
    return nil
  }
}

nonisolated struct BrowserSnapshotDelta: Equatable, Sendable {
  var changed: [[String]] = []
  var added: [[String]] = []
  var removed: [[String]] = []

  var isEmpty: Bool { changed.isEmpty && added.isEmpty && removed.isEmpty }

  init(from previous: String, to current: String) {
    let before = Units(BrowserSnapshotText.parse(previous))
    let after = Units(BrowserSnapshotText.parse(current))
    for ref in after.order {
      guard let unit = after.units[ref] else { continue }
      guard let earlier = before.units[ref] else {
        if unit.parent.map({ before.units[$0] != nil }) ?? true {
          added.append(after.subtree(of: unit))
        }
        continue
      }
      guard earlier.signature != unit.signature else { continue }
      if unit.signature.count == 1, unit.signature[0] == earlier.signature[0] {
        removed.append(earlier.signature.dropFirst().map { String($0.drop(while: { $0 == " " })) })
      } else {
        changed.append(Self.entry(unit.signature))
      }
    }
    for ref in before.order where after.units[ref] == nil {
      guard let unit = before.units[ref], unit.parent.map({ after.units[$0] != nil }) ?? true else { continue }
      removed.append([unit.signature[0]])
    }
  }

  private static func entry(_ signature: [String]) -> [String] {
    guard signature.count > 1, signature[0].hasSuffix("]") || signature[0].hasSuffix("]'") else { return signature }
    return [signature[0] + ":"] + signature.dropFirst()
  }

  func rendered(maxLines: Int) -> String {
    guard !isEmpty else { return "no visible change" }
    var lines: [String] = []
    var remaining = maxLines
    var hidden = 0
    for (title, entries) in [("changed:", changed), ("added:", added), ("removed:", removed)] {
      let entryLines = entries.flatMap(\.self)
      let shown = entryLines.prefix(max(remaining, 0))
      hidden += entryLines.count - shown.count
      remaining -= shown.count
      guard !shown.isEmpty else { continue }
      lines.append(title)
      lines.append(contentsOf: shown)
    }
    if hidden > 0 {
      lines.append("... \(hidden) more changed lines. Run `snapshot` for the page.")
    }
    return lines.joined(separator: "\n")
  }

  private struct Unit {
    var start: Int
    var end: Int
    var parent: String?
    var signature: [String]
  }

  private struct Units {
    var units: [String: Unit] = [:]
    var order: [String] = []
    private let lines: [BrowserSnapshotText.Line]

    init(_ lines: [BrowserSnapshotText.Line]) {
      self.lines = lines
      var open: [(indent: Int, ref: String?)] = []
      for (index, line) in lines.enumerated() {
        while let last = open.last, last.indent >= line.indent {
          open.removeLast()
          if let ref = last.ref {
            units[ref]?.end = index
          }
        }
        let owner = open.last(where: { $0.ref != nil })?.ref
        if let ref = line.ref {
          let key = "- " + BrowserSnapshotText.closingKey(line.content)
          units[ref] = Unit(start: index, end: lines.count, parent: owner, signature: [key])
          order.append(ref)
        } else if let owner, let ownerStart = units[owner]?.start {
          let relative = String(repeating: " ", count: line.indent - lines[ownerStart].indent)
          units[owner]?.signature.append(relative + "- " + line.content)
        }
        open.append((line.indent, line.ref))
      }
    }

    func subtree(of unit: Unit) -> [String] {
      let base = lines[unit.start].indent
      return lines[unit.start..<unit.end].map { line in
        String(repeating: " ", count: line.indent - base) + "- " + line.content
      }
    }
  }
}
