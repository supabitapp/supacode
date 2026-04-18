/// ANSI formatting for list output.
nonisolated func formatListLine(_ text: String, focused: Bool) -> String {
  focused ? "\u{1B}[4m\(text)\u{1B}[0m" : text
}

/// Formats a script row from the `scripts` query as tab-separated
/// columns: `<uuid>\t<kind>\t<displayName>`. Running scripts are
/// underlined so humans can spot them at a glance.
nonisolated func formatScriptListLine(_ row: [String: String], running: Bool) -> String {
  let id = row["id"] ?? ""
  let kind = row["kind"] ?? ""
  let name = row["displayName"] ?? row["name"] ?? ""
  let line = "\(id)\t\(kind)\t\(name)"
  return formatListLine(line, focused: running)
}
