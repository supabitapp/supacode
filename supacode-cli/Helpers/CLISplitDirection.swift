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
