import ArgumentParser

/// Split direction for CLI argument parsing. Accepts "h"/"v" abbreviations.
/// Keep in sync with `SplitDirection` in `supacode/Domain/SplitDirection.swift`.
nonisolated enum CLISplitDirection: String, CaseIterable, ExpressibleByArgument {
  case horizontal
  case vertical

  nonisolated static var allValueStrings: [String] { ["horizontal", "h", "vertical", "v"] }

  nonisolated init?(argument: String) {
    switch argument {
    case "horizontal", "h": self = .horizontal
    case "vertical", "v": self = .vertical
    default: return nil
    }
  }
}

/// Four-way direction for `pane focus` and `tab move`. Accepts single-letter
/// abbreviations. Keep in sync with `TerminalSplitMenuDirection`.
nonisolated enum CLIFocusDirection: String, CaseIterable, ExpressibleByArgument {
  case left
  case right
  case up
  case down

  nonisolated static var allValueStrings: [String] {
    ["left", "l", "right", "r", "up", "u", "down", "d"]
  }

  nonisolated init?(argument: String) {
    switch argument {
    case "left", "l": self = .left
    case "right", "r": self = .right
    case "up", "u": self = .up
    case "down", "d": self = .down
    default: return nil
    }
  }
}
