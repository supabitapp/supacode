import Foundation

private nonisolated let jcodeInstallerLogger = SupaLogger("Settings")

/// Installs and removes jcode's presence hooks. Owns two on-disk artifacts:
///
/// 1. The Supacode-managed entries in jcode's `[hooks]` table (in
///    `~/.jcode/config.toml`) — one per lifecycle event, each invoking the
///    presence-hook wrapper below.
/// 2. The wrapper itself, `~/.jcode/hooks/supacode-presence.sh`, written as a
///    whole-file replacement and made executable via `chmod 0755` (as in
///    `CopilotHooksInstaller`).
///
/// Like the Kimi installers, this is a structured read-modify-write of a
/// `config.toml` keyed on ownership, but jcode uses a `[hooks]` *table*
/// (`event = command`) rather than Kimi's `[[hooks]]` array-of-tables, and each
/// entry points at the wrapper because jcode exec's hooks directly (see
/// `JcodeHookSettings`). jcode activates hooks from its config alone, so there is
/// no version probe and no feature flag to gate on.
///
/// Ownership of `[hooks]` entries is keyed on the wrapper path: an entry — or one
/// element of an array value — equal to the wrapper path is Supacode's. Install is
/// an idempotent prune-and-replace of only those entries, so a user's own hook on
/// the same event is preserved by merging it into an array; uninstall removes only
/// Supacode's entries and wrapper, leaving any user value intact.
///
/// Note: value scanning is single-line (a TOML string or inline array). A
/// hooked-event value split across multiple lines (a rare multi-line array) is
/// left untouched rather than rewritten; this can be revisited as a follow-up if
/// a user hits it.
nonisolated struct JcodeSettingsInstaller {
  let homeDirectoryURL: URL
  let fileManager: FileManager
  let logWarning: @Sendable (String) -> Void

  init(
    homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
    fileManager: FileManager = .default,
    logWarning: @escaping @Sendable (String) -> Void = { jcodeInstallerLogger.warning($0) },
  ) {
    self.homeDirectoryURL = homeDirectoryURL
    self.fileManager = fileManager
    self.logWarning = logWarning
  }

  // MARK: - Install state.

  /// Reports `.installed` only when both artifacts are current: every lifecycle
  /// event references the wrapper AND the wrapper file matches its canonical body.
  /// A partial or stale install is `.outdated` (so auto-update can repair it);
  /// nothing present at all is `.notInstalled`.
  func installState() throws -> ComponentInstallState {
    let wrapperPath = wrapperURL.path(percentEncoded: false)
    let managed: Set<String>
    do {
      managed = Self.managedEvents(in: try readText(at: settingsURL), wrapperPath: wrapperPath)
    } catch {
      logWarning("Failed to inspect jcode hook settings at \(settingsURL.path): \(error.localizedDescription)")
      throw error
    }
    let wrapperText = try AgentFileProbe.text(at: wrapperURL)
    if managed.isEmpty, wrapperText == nil { return .notInstalled }
    let allEventsManaged = managed == Set(JcodeHookSettings.hookedEvents)
    let wrapperCurrent = wrapperText == JcodeHookSettings.wrapperScript()
    return allEventsManaged && wrapperCurrent ? .installed : .outdated
  }

  // MARK: - Install / uninstall.

  func installAllHooks() throws {
    let wrapperPath = wrapperURL.path(percentEncoded: false)
    let text = try readText(at: settingsURL)
    let updated = Self.installed(
      into: text, wrapperPath: wrapperPath, events: JcodeHookSettings.hookedEvents)
    try installWrapper()
    try writeText(updated, to: settingsURL)
  }

  func uninstallAllHooks() throws {
    let wrapperPath = wrapperURL.path(percentEncoded: false)
    let text = try readText(at: settingsURL)
    let updated = Self.uninstalled(
      from: text, wrapperPath: wrapperPath, events: JcodeHookSettings.hookedEvents)
    try writeText(updated, to: settingsURL)
    try removeWrapper()
  }

  // MARK: - Paths.

  var settingsURL: URL { Self.settingsURL(homeDirectoryURL: homeDirectoryURL) }

  static func settingsURL(homeDirectoryURL: URL) -> URL {
    homeDirectoryURL
      .appending(path: SkillAgent.jcode.configDirectoryName, directoryHint: .isDirectory)
      .appending(path: "config.toml", directoryHint: .notDirectory)
  }

  var wrapperURL: URL { JcodeHookSettings.wrapperURL(homeDirectoryURL: homeDirectoryURL) }

  // MARK: - Wrapper file (whole-file write, executable).

  private func installWrapper() throws {
    try fileManager.createDirectory(
      at: wrapperURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let data = JcodeHookSettings.wrapperScript().data(using: .utf8) else {
      throw JcodeSettingsInstallerError.invalidUTF8
    }
    try data.write(to: wrapperURL, options: .atomic)
    // An atomic write lands a fresh inode with umask perms; restore the executable bits.
    try fileManager.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: wrapperURL.path(percentEncoded: false))
  }

  /// Removes the wrapper only when it is Supacode's (carries the ownership marker),
  /// so a user file that happens to share the name is never deleted.
  private func removeWrapper() throws {
    guard let text = try AgentFileProbe.text(at: wrapperURL) else { return }
    guard text.contains(AgentHookSettingsCommand.ownershipMarker) else { return }
    try fileManager.removeItem(at: wrapperURL)
  }

  // MARK: - Text I/O.

  private func readText(at url: URL) throws -> String {
    guard let data = try AgentFileProbe.data(at: url) else { return "" }
    guard let text = String(data: data, encoding: .utf8) else {
      throw JcodeSettingsInstallerError.invalidUTF8
    }
    return text.replacing("\r\n", with: "\n").replacing("\r", with: "\n")
  }

  private func writeText(_ text: String, to url: URL) throws {
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let data = text.data(using: .utf8) else {
      throw JcodeSettingsInstallerError.invalidUTF8
    }
    try data.write(to: url, options: .atomic)
  }

  // MARK: - `[hooks]` table editing (internal for unit tests).

  /// The lifecycle events whose `[hooks]` value carries `wrapperPath` — i.e. those
  /// Supacode currently manages. Ownership here is deliberately path-based, not the
  /// shared `AgentHookCommandOwnership` marker other harnesses key on; the
  /// `# supacode-managed-hook` comment that `render` appends to managed lines is
  /// human-readable only and is never consulted for detection.
  static func managedEvents(in text: String, wrapperPath: String) -> Set<String> {
    let lines = text.components(separatedBy: "\n")
    guard let range = hooksBodyRange(in: lines) else { return [] }
    var found = Set<String>()
    for line in lines[range] {
      guard
        let (key, rhs) = assignment(in: line),
        JcodeHookSettings.hookedEvents.contains(key)
      else { continue }
      if quotedStrings(in: rhs).contains(wrapperPath) { found.insert(key) }
    }
    return found
  }

  /// Returns `text` with the wrapper present on every event in `events`. Existing
  /// user values on those events are preserved by merging them into an array; any
  /// prior Supacode entry is replaced. All other content is left untouched.
  static func installed(into text: String, wrapperPath: String, events: [String]) -> String {
    let eventSet = Set(events)
    var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")

    // Collect user values (everything but the wrapper) from existing lines for
    // our events, and drop those lines; canonical lines are re-added below.
    var userValues: [String: [String]] = [:]
    if let range = hooksBodyRange(in: lines) {
      var otherLines: [String] = []
      for line in lines[range] {
        if let (key, rhs) = assignment(in: line), eventSet.contains(key) {
          let users = quotedStrings(in: rhs).filter { $0 != wrapperPath }
          userValues[key, default: []].append(contentsOf: users)
          continue
        }
        otherLines.append(line)
      }
      // Canonical entries first, then any other `[hooks]` content (user keys or
      // comments), blank-trimmed so re-install is byte-idempotent.
      let canonical = events.map {
        render(event: $0, values: (userValues[$0] ?? []) + [wrapperPath], managed: true)
      }
      let preservedUser = trimmedBlankEdges(otherLines)
      let newBody = canonical + (preservedUser.isEmpty ? [] : [""] + preservedUser)
      lines.replaceSubrange(range, with: newBody)
      return normalizedTrailingNewline(lines.joined(separator: "\n"))
    }

    // No `[hooks]` section yet — append one.
    let canonical = events.map { render(event: $0, values: [wrapperPath], managed: true) }
    var result = text
    if !result.isEmpty {
      if !result.hasSuffix("\n") { result.append("\n") }
      if !result.hasSuffix("\n\n") { result.append("\n") }
    }
    result += (["[hooks]"] + canonical).joined(separator: "\n")
    return normalizedTrailingNewline(result)
  }

  /// Returns `text` with the wrapper removed from every event in `events`. An event
  /// left with only user values is rewritten to keep them; an event left with
  /// nothing (it was Supacode's alone) is dropped entirely.
  static func uninstalled(from text: String, wrapperPath: String, events: [String]) -> String {
    let eventSet = Set(events)
    var lines = text.components(separatedBy: "\n")
    guard let range = hooksBodyRange(in: lines) else { return text }
    var body: [String] = []
    for line in lines[range] {
      guard let (key, rhs) = assignment(in: line), eventSet.contains(key) else {
        body.append(line)
        continue
      }
      let users = quotedStrings(in: rhs).filter { $0 != wrapperPath }
      if users.isEmpty { continue }  // was Supacode's alone — drop the line.
      body.append(render(event: key, values: users, managed: false))
    }
    lines.replaceSubrange(range, with: body)
    return normalizedTrailingNewline(lines.joined(separator: "\n"))
  }

  // MARK: - Line/section parsing.

  /// Body-line range of the first `[hooks]` table (excluding its header), running
  /// to the next section header or EOF. `nil` when there is no `[hooks]` table.
  static func hooksBodyRange(in lines: [String]) -> Range<Int>? {
    guard let header = lines.firstIndex(where: isHooksHeader) else { return nil }
    var end = header + 1
    while end < lines.count, !isSectionHeader(lines[end]) { end += 1 }
    return (header + 1)..<end
  }

  /// A `key = value` assignment (key + raw right-hand side), or `nil` for a
  /// comment, blank, or section-header line.
  static func assignment(in line: String) -> (key: String, rhs: String)? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("[") else { return nil }
    guard let equals = trimmed.firstIndex(of: "=") else { return nil }
    let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
    guard !key.isEmpty else { return nil }
    return (key, String(trimmed[trimmed.index(after: equals)...]))
  }

  /// The TOML string values in a right-hand side — a single basic/literal string
  /// or an inline array of them. A `#` outside any string ends the scan (trailing
  /// comment). Basic-string escapes are decoded; literal strings are verbatim.
  static func quotedStrings(in rhs: String) -> [String] {
    var values: [String] = []
    let chars = Array(rhs)
    var index = 0
    while index < chars.count {
      switch chars[index] {
      case "#":
        return values  // Trailing comment (we only reach here outside a string).
      case "\"":
        let (value, next) = scanBasicString(chars, from: index + 1)
        index = next
        if let value { values.append(value) }
      case "'":
        let (value, next) = scanLiteralString(chars, from: index + 1)
        index = next
        if let value { values.append(value) }
      default:
        index += 1
      }
    }
    return values
  }

  /// Scans a TOML basic string starting just after the opening `"`. Returns the
  /// decoded value (nil if unterminated) and the index just past the closing `"`.
  private static func scanBasicString(
    _ chars: [Character], from start: Int
  ) -> (value: String?, next: Int) {
    var index = start
    var value = ""
    var escaped = false
    while index < chars.count {
      let char = chars[index]
      index += 1
      if escaped {
        value.append(Self.unescapeBasic(char))
        escaped = false
      } else if char == "\\" {
        escaped = true
      } else if char == "\"" {
        return (value, index)
      } else {
        value.append(char)
      }
    }
    return (nil, index)
  }

  private static func unescapeBasic(_ char: Character) -> Character {
    switch char {
    case "n": "\n"
    case "r": "\r"
    case "t": "\t"
    default: char
    }
  }

  /// Scans a TOML literal string (verbatim, no escapes) starting just after the
  /// opening `'`. Returns the value (nil if unterminated) and the next index.
  private static func scanLiteralString(
    _ chars: [Character], from start: Int
  ) -> (value: String?, next: Int) {
    var index = start
    var value = ""
    while index < chars.count {
      let char = chars[index]
      index += 1
      if char == "'" { return (value, index) }
      value.append(char)
    }
    return (nil, index)
  }

  /// Renders one `[hooks]` entry: a bare string for a single value, an inline
  /// array for several. Managed entries carry the ownership marker as a trailing
  /// comment so a human reading the file sees who owns the line.
  static func render(event: String, values: [String], managed: Bool) -> String {
    let rhs =
      values.count == 1
      ? tomlQuote(values[0])
      : "[\(values.map(tomlQuote).joined(separator: ", "))]"
    let suffix = managed ? "  \(AgentHookSettingsCommand.ownershipMarker)" : ""
    return "\(event) = \(rhs)\(suffix)"
  }

  private static func isHooksHeader(_ line: String) -> Bool {
    line.trimmingCharacters(in: .whitespaces)
      .range(of: #"^\[\s*hooks\s*\]\s*(#.*)?$"#, options: .regularExpression) != nil
  }

  /// Any TOML table (`[section]`) or array-of-tables (`[[section]]`) header, which
  /// ends the current section's scope. A `key = value` line is rejected by the
  /// leading-`[` guard inside the regex.
  private static func isSectionHeader(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("[") else { return false }
    let keySegment = #"(?:[A-Za-z0-9_\-]+|"(?:[^"\\]|\\.)*"|'[^']*')"#
    let pattern = #"^\[\[?\s*"# + keySegment + #"(?:\s*\.\s*"# + keySegment + #")*\s*\]\]?\s*(#.*)?$"#
    return trimmed.range(of: pattern, options: .regularExpression) != nil
  }

  /// Quotes a string as a TOML basic string, escaping `\`, `"`, and common
  /// control characters.
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

  private static func normalizedTrailingNewline(_ text: String) -> String {
    var result = text
    while result.hasSuffix("\n") { result.removeLast() }
    return result.isEmpty ? "" : result + "\n"
  }

  /// Drops leading and trailing blank lines, so preserved content re-inserts at a
  /// stable position and a re-install is byte-identical.
  private static func trimmedBlankEdges(_ lines: [String]) -> [String] {
    var result = lines
    while let first = result.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
      result.removeFirst()
    }
    while let last = result.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
      result.removeLast()
    }
    return result
  }
}

nonisolated enum JcodeSettingsInstallerError: Error, Equatable, LocalizedError {
  case invalidUTF8

  var errorDescription: String? {
    switch self {
    case .invalidUTF8:
      "jcode's config.toml is not valid UTF-8. Fix or remove ~/.jcode/config.toml and try again."
    }
  }
}
