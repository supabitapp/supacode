import Darwin

nonisolated enum ListFormatting {
  /// ANSI formatting for list output. The underline is only emitted to a TTY so
  /// a captured / piped id (e.g. `worktree list | head -1`) stays clean.
  static func line(_ text: String, focused: Bool) -> String {
    guard focused, isatty(STDOUT_FILENO) != 0 else { return text }
    return "\u{1B}[4m\(text)\u{1B}[0m"
  }

  /// Formats a script row from the `scripts` query as tab-separated
  /// columns: `<uuid>\t<kind>\t<displayName>`. Running scripts are
  /// underlined so humans can spot them at a glance.
  static func scriptLine(_ row: [String: String], running: Bool) -> String {
    let id = sanitizeColumn(row["id"] ?? "")
    let kind = sanitizeColumn(row["kind"] ?? "")
    let name = sanitizeColumn(row["displayName"] ?? row["name"] ?? "")
    return line("\(id)\t\(kind)\t\(name)", focused: running)
  }

  /// Keeps tabs and newlines out of a tab-separated column so an embedded
  /// character cannot forge an extra column downstream.
  static func sanitizeColumn(_ value: String) -> String {
    value.replacing("\t", with: " ").replacing("\n", with: " ").replacing("\r", with: " ")
  }
}
