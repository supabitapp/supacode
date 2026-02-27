#if canImport(cmark_gfm)
  import cmark_gfm
#elseif canImport(cmark)
  import cmark
#else
  #error("swift-cmark is required")
#endif

enum NotificationTextNormalizer {
  private typealias CMarkNode = UnsafeMutablePointer<cmark_node>

  static func normalize(_ text: String) -> String {
    guard text.contains(where: { !$0.isWhitespace }) else { return "" }
    guard let root = parseMarkdown(text) else { return collapseWhitespace(text) }
    defer { cmark_node_free(root) }

    var normalized = ""
    appendText(from: root, into: &normalized)
    return collapseWhitespace(normalized)
  }

  private static let literalNodeTypes: Set<String> = [
    "text",
    "code",
    "code_block",
    "html_inline",
    "html_block",
  ]

  private static let blockBoundaryNodeTypes: Set<String> = [
    "paragraph",
    "heading",
    "block_quote",
    "list",
    "item",
    "thematic_break",
    "table",
    "table_row",
    "table_cell",
  ]

  private static func parseMarkdown(_ markdown: String) -> CMarkNode? {
    markdown.utf8CString.withUnsafeBufferPointer { buffer in
      guard let baseAddress = buffer.baseAddress else { return nil }
      return cmark_parse_document(baseAddress, buffer.count - 1, 0)
    }
  }

  private static func appendText(from node: CMarkNode?, into output: inout String) {
    guard let node else { return }

    let type = nodeType(node)
    if literalNodeTypes.contains(type), let literal = cmark_node_get_literal(node) {
      var text = String(cString: literal)
      if isLeadingTaskListMarker(node) {
        text = stripTaskListPrefix(text)
      }
      output.append(text)
    }

    if type == "softbreak" || type == "linebreak" {
      output.append("\n")
    }

    var child: CMarkNode? = cmark_node_first_child(node)
    while let currentChild = child {
      appendText(from: currentChild, into: &output)
      child = cmark_node_next(currentChild)
    }

    if blockBoundaryNodeTypes.contains(type) {
      output.append("\n")
    }
  }

  private static func nodeType(_ node: CMarkNode) -> String {
    guard let cString = cmark_node_get_type_string(node) else { return "" }
    return String(cString: cString)
  }

  private static func isLeadingTaskListMarker(_ node: CMarkNode) -> Bool {
    guard
      let parent = cmark_node_parent(node),
      nodeType(parent) == "paragraph",
      let grandparent = cmark_node_parent(parent),
      nodeType(grandparent) == "item"
    else {
      return false
    }

    guard let firstParagraphChild = cmark_node_first_child(parent), firstParagraphChild == node else {
      return false
    }

    guard let literal = cmark_node_get_literal(node) else { return false }
    let text = String(cString: literal)
    return text.hasPrefix("[ ] ") || text.hasPrefix("[x] ") || text.hasPrefix("[X] ")
  }

  private static func stripTaskListPrefix(_ text: String) -> String {
    if text.hasPrefix("[ ] ") || text.hasPrefix("[x] ") || text.hasPrefix("[X] ") {
      return String(text.dropFirst(4))
    }
    return text
  }

  private static func collapseWhitespace(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }
}
