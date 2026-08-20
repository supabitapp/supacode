/// Normalized pull request state, decoded case-insensitively so forge-specific
/// casings ("MERGED" vs "merged") and synonyms ("OPENED") map to one value.
nonisolated enum PullRequestState: Equatable, Hashable {
  case open
  case merged
  case closed
  case unknown(String)

  init(rawValue: String) {
    switch rawValue.uppercased() {
    case "OPEN", "OPENED": self = .open
    case "MERGED": self = .merged
    case "CLOSED": self = .closed
    // Uppercased so equality is casing-blind, matching the folded cases.
    default: self = .unknown(rawValue.uppercased())
    }
  }

  /// Branch-to-proposal tie-break rank shared by every adapter: an open
  /// proposal beats a merged one beats the rest.
  var matchRank: Int {
    switch self {
    case .open: 2
    case .merged: 1
    case .closed, .unknown: 0
    }
  }

  /// Uppercase label matching the forge-style badge rendering.
  var displayLabel: String {
    switch self {
    case .open: "OPEN"
    case .merged: "MERGED"
    case .closed: "CLOSED"
    case .unknown(let rawValue): rawValue
    }
  }
}

extension PullRequestState: Decodable {
  init(from decoder: Decoder) throws {
    self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
  }
}
