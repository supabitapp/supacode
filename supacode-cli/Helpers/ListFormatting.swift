/// ANSI formatting for list output.
nonisolated func formatListLine(_ text: String, focused: Bool) -> String {
  focused ? "\u{1B}[4m\(text)\u{1B}[0m" : text
}
