import Darwin

/// ANSI formatting for list output. The underline is only emitted to a TTY so
/// a captured / piped id (e.g. `worktree list | head -1`) stays clean.
nonisolated func formatListLine(_ text: String, focused: Bool) -> String {
  guard focused, isatty(STDOUT_FILENO) != 0 else { return text }
  return "\u{1B}[4m\(text)\u{1B}[0m"
}

/// Formats a script row from the `scripts` query as tab-separated
/// columns: `<uuid>\t<kind>\t<displayName>`. Running scripts are
/// underlined so humans can spot them at a glance. Tabs and newlines
/// embedded in user-editable names are replaced with spaces so they
/// cannot corrupt the column layout when piped to other tools.
nonisolated func formatScriptListLine(_ row: [String: String], running: Bool) -> String {
  let id = sanitizeColumnValue(row["id"] ?? "")
  let kind = sanitizeColumnValue(row["kind"] ?? "")
  let name = sanitizeColumnValue(row["displayName"] ?? row["name"] ?? "")
  let line = "\(id)\t\(kind)\t\(name)"
  return formatListLine(line, focused: running)
}

private nonisolated func sanitizeColumnValue(_ value: String) -> String {
  value.replacing("\t", with: " ").replacing("\n", with: " ").replacing("\r", with: " ")
}
