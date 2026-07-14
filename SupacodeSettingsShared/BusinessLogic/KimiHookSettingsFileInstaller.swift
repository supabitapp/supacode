import Foundation

private nonisolated let kimiInstallerLogger = SupaLogger("Settings")

/// TOML installer for Kimi's `[[hooks]]` array-of-tables in
/// `~/.kimi-code/config.toml`. Operates on the file as structured text: identifies
/// `[[hooks]]` block boundaries, drops Supacode-owned blocks (by `command`
/// sentinel), and appends canonical blocks. All other content (TOML sections,
/// comments, blank lines) is preserved; line endings are normalized to LF on
/// any write.
nonisolated struct KimiHookSettingsFileInstaller {
  let fileManager: FileManager
  let logWarning: @Sendable (String) -> Void

  init(
    fileManager: FileManager,
    logWarning: @escaping @Sendable (String) -> Void = { kimiInstallerLogger.warning($0) },
  ) {
    self.fileManager = fileManager
    self.logWarning = logWarning
  }

  // MARK: - Install state.

  func installState(
    settingsURL: URL,
    canonicalEntries: [KimiHookEntry],
  ) -> ComponentInstallState {
    let expected = Set(canonicalEntries.map(\.command))
    guard !expected.isEmpty else { return .notInstalled }
    do {
      let text = try readText(at: settingsURL)
      let actual = Self.supacodeManagedCommands(in: text)
      if actual.isEmpty { return .notInstalled }
      return actual == expected ? .installed : .outdated
    } catch {
      logWarning(
        "Failed to inspect Kimi hook settings at \(settingsURL.path): \(error.localizedDescription)")
      return .notInstalled
    }
  }

  // MARK: - Install.

  func install(
    settingsURL: URL,
    canonicalEntries: [KimiHookEntry],
  ) throws {
    var text = try readText(at: settingsURL)
    text = Self.pruneSupacodeBlocks(from: text)
    text = Self.appendCanonicalEntries(canonicalEntries, to: text)
    try writeText(text, to: settingsURL)
  }

  // MARK: - Uninstall.

  func uninstall(
    settingsURL: URL,
    canonicalEntries: [KimiHookEntry],
  ) throws {
    _ = canonicalEntries  // Parity with `install` for signature symmetry.
    var text = try readText(at: settingsURL)
    text = Self.pruneSupacodeBlocks(from: text)
    try writeText(text, to: settingsURL)
  }

  // MARK: - Text I/O.

  private func readText(at url: URL) throws -> String {
    guard fileManager.fileExists(atPath: url.path) else { return "" }
    let data = try Data(contentsOf: url)
    guard let text = String(data: data, encoding: .utf8) else {
      throw KimiHookSettingsFileError.invalidUTF8
    }
    // Normalize line endings so block scanning is endings-agnostic.
    return text.replacing("\r\n", with: "\n").replacing("\r", with: "\n")
  }

  private func writeText(_ text: String, to url: URL) throws {
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true,
    )
    guard let data = text.data(using: .utf8) else {
      throw KimiHookSettingsFileError.invalidUTF8
    }
    try data.write(to: url, options: .atomic)
  }

  // MARK: - Block parsing (internal for unit tests).

  /// Set of Supacode-managed `command` values found in any `[[hooks]]`
  /// block in `text`. Identifies a hook block by its `[[hooks]]` header
  /// line and scans until the next `[[hooks]]` or any `[section]` line.
  static func supacodeManagedCommands(in text: String) -> Set<String> {
    var commands = Set<String>()
    for block in hookBlocks(in: text) {
      guard
        let command = commandValue(in: block),
        AgentHookCommandOwnership.isSupacodeManagedCommand(command)
      else { continue }
      commands.insert(command)
    }
    return commands
  }

  /// Removes every `[[hooks]]` block whose `command` is Supacode-managed.
  /// Preserves all other content. Returns the rewritten text.
  static func pruneSupacodeBlocks(from text: String) -> String {
    let lines = text.components(separatedBy: "\n")
    var result: [String] = []
    var index = 0
    while index < lines.count {
      if isHooksArrayHeader(lines[index]) {
        let blockStart = index
        index += 1
        while index < lines.count, !isAnySectionHeader(lines[index]) {
          index += 1
        }
        let blockText = lines[blockStart..<index].joined(separator: "\n")
        if let command = commandValue(in: blockText),
          AgentHookCommandOwnership.isSupacodeManagedCommand(command)
        {
          // Drop the managed block but keep trailing comment lines, which
          // belong to the user. Blank separators are dropped so re-install
          // stays idempotent.
          result.append(contentsOf: trailingUserComments(in: lines, blockStart..<index))
          continue
        }
        result.append(contentsOf: lines[blockStart..<index])
      } else {
        result.append(lines[index])
        index += 1
      }
    }
    return result.joined(separator: "\n")
  }

  /// Appends canonical `[[hooks]]` blocks to `text` with one blank separator
  /// line, ensuring a trailing newline.
  static func appendCanonicalEntries(
    _ entries: [KimiHookEntry],
    to text: String,
  ) -> String {
    guard !entries.isEmpty else { return text }
    var result = text
    if !result.isEmpty {
      if !result.hasSuffix("\n") { result.append("\n") }
      if !result.hasSuffix("\n\n") { result.append("\n") }
    }
    result += entries.map(Self.renderBlock).joined(separator: "\n\n")
    if !result.hasSuffix("\n") { result.append("\n") }
    return result
  }

  /// Renders a single `[[hooks]]` block in canonical form.
  static func renderBlock(_ entry: KimiHookEntry) -> String {
    var lines: [String] = ["[[hooks]]"]
    lines.append("event = \(tomlQuote(entry.event))")
    lines.append("command = \(tomlQuote(entry.command))")
    if !entry.matcher.isEmpty {
      lines.append("matcher = \(tomlQuote(entry.matcher))")
    }
    lines.append("timeout = \(entry.timeout)")
    return lines.joined(separator: "\n")
  }

  // MARK: - Block scanning helpers.

  /// Bodies of every `[[hooks]]` block in `text` (including the header line).
  /// A block runs from its header until the next `[[hooks]]`, any other
  /// `[section]` header, or EOF.
  private static func hookBlocks(in text: String) -> [String] {
    let lines = text.components(separatedBy: "\n")
    var blocks: [String] = []
    var index = 0
    while index < lines.count {
      if isHooksArrayHeader(lines[index]) {
        let start = index
        index += 1
        while index < lines.count, !isAnySectionHeader(lines[index]) {
          index += 1
        }
        blocks.append(lines[start..<index].joined(separator: "\n"))
      } else {
        index += 1
      }
    }
    return blocks
  }

  /// Trailing comment lines in `range` that follow the last block-owned
  /// (non-blank, non-comment) line. These belong to the user and survive a
  /// managed-block prune; blank separators are dropped to keep re-install
  /// idempotent.
  private static func trailingUserComments(in lines: [String], _ range: Range<Int>) -> [String] {
    var lastOwned = range.lowerBound
    for index in range {
      let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
      if !trimmed.isEmpty, !trimmed.hasPrefix("#") { lastOwned = index }
    }
    return lines[(lastOwned + 1)..<range.upperBound].filter {
      $0.trimmingCharacters(in: .whitespaces).hasPrefix("#")
    }
  }

  /// Value of the `command` field in a `[[hooks]]` block body, or nil when the
  /// block has no `command =` line. Honors TOML basic strings (`"..."`, with
  /// escapes) and literal strings (`'...'`, verbatim) so a managed block is
  /// still recognized if Kimi rewrites the command as a literal string.
  private static func commandValue(in block: String) -> String? {
    let lines = block.components(separatedBy: "\n")
    for rawLine in lines {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard isCommandKeyLine(line) else { continue }
      guard let equalsIndex = line.firstIndex(of: "=") else { continue }
      let after = line[line.index(after: equalsIndex)...].trimmingCharacters(in: .whitespaces)
      if after.hasPrefix("\"") {
        return unescapeBasicString(String(after.dropFirst()))
      }
      if after.hasPrefix("'") {
        return literalStringValue(String(after.dropFirst()))
      }
    }
    return nil
  }

  /// Body of a TOML literal string (the bytes after the opening `'`), up to the
  /// first `'`. Literal strings have no escapes. Returns nil when unterminated.
  private static func literalStringValue(_ body: String) -> String? {
    guard let end = body.firstIndex(of: "'") else { return nil }
    return String(body[body.startIndex..<end])
  }

  /// True when `line` is a `command = ...` key assignment (not `commander`,
  /// `command_timeout`, etc.). The key must be followed by whitespace or `=`.
  private static func isCommandKeyLine(_ line: String) -> Bool {
    guard line.hasPrefix("command") else { return false }
    let afterKey = line.dropFirst("command".count)
    guard let first = afterKey.first else { return false }
    return first == "=" || first.isWhitespace
  }

  /// Walks a TOML basic string body (the bytes after the opening `"`),
  /// unescaping `\"`, `\\`, `\n`, `\r`, `\t` and stopping at the first
  /// unescaped `"`. Returns nil if the string is not closed.
  private static func unescapeBasicString(_ body: String) -> String? {
    var result = ""
    var escaped = false
    var closed = false
    for char in body {
      if escaped {
        switch char {
        case "\\": result.append("\\")
        case "\"": result.append("\"")
        case "n": result.append("\n")
        case "r": result.append("\r")
        case "t": result.append("\t")
        default: result.append(char)
        }
        escaped = false
        continue
      }
      if char == "\\" {
        escaped = true
        continue
      }
      if char == "\"" {
        closed = true
        break
      }
      result.append(char)
    }
    return closed ? result : nil
  }

  /// True when `line` is the TOML `[[hooks]]` array-of-tables header,
  /// tolerating interior whitespace and a trailing comment.
  private static func isHooksArrayHeader(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("[") else { return false }
    return trimmed.range(
      of: #"^\[\[\s*hooks\s*\]\]\s*(#.*)?$"#,
      options: .regularExpression,
    ) != nil
  }

  /// True when `line` opens a new TOML table (`[section]`) or array-of-tables
  /// (`[[section]]`), which ends the current block scope. Matches dotted and
  /// quoted keys (`[mcp."my server"]`) and interior whitespace (`[ a.b ]`); a
  /// `key = value` line is rejected by the leading-`[` guard.
  private static func isAnySectionHeader(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("[") else { return false }
    return trimmed.range(of: Self.sectionHeaderRegex, options: .regularExpression) != nil
  }

  /// Matches a TOML table / array-of-tables header: `[` or `[[`, a dotted path
  /// of bare or quoted key segments (whitespace allowed around them), then the
  /// closing brackets and an optional comment. Excludes array values such as
  /// `[1, 2]`, since a key segment cannot contain a comma.
  private static let sectionHeaderRegex: String = {
    let keySegment = #"(?:[A-Za-z0-9_\-]+|"(?:[^"\\]|\\.)*"|'[^']*')"#
    return #"^\[\[?\s*"# + keySegment + #"(?:\s*\.\s*"# + keySegment + #")*\s*\]\]?\s*(#.*)?$"#
  }()

  /// Quotes a string for TOML basic-string emission. Escapes `\`, `"`, and
  /// the common control characters.
  private static func tomlQuote(_ value: String) -> String {
    var escaped = ""
    for char in value {
      switch char {
      case "\\": escaped.append("\\\\")
      case "\"": escaped.append("\\\"")
      case "\n": escaped.append("\\n")
      case "\r": escaped.append("\\r")
      case "\t": escaped.append("\\t")
      default: escaped.append(char)
      }
    }
    return "\"\(escaped)\""
  }
}

nonisolated enum KimiHookSettingsFileError: Error, Equatable, LocalizedError {
  case invalidUTF8

  var errorDescription: String? {
    switch self {
    case .invalidUTF8:
      "Kimi's config.toml is not valid UTF-8. Fix or remove ~/.kimi-code/config.toml and try again."
    }
  }
}
