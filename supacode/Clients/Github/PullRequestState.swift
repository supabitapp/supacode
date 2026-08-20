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
    default: self = .unknown(rawValue)
    }
  }

  /// Uppercase label matching the forge-style badge rendering.
  var displayLabel: String {
    switch self {
    case .open: "OPEN"
    case .merged: "MERGED"
    case .closed: "CLOSED"
    case .unknown(let rawValue): rawValue.uppercased()
    }
  }
}

extension PullRequestState: Decodable {
  init(from decoder: Decoder) throws {
    self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
  }
}
