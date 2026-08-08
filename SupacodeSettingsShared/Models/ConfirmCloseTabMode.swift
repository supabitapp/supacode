import Foundation

/// How aggressively to prompt before closing a tab. zmx keeps terminal
/// sessions alive, so a close only risks losing work when the content is busy;
/// `.busy` confirms exactly then, and is the default.
public nonisolated enum ConfirmCloseTabMode: String, Codable, CaseIterable, Sendable {
  case busy
  case always
  case never

  public var label: String {
    switch self {
    case .busy: "When Busy"
    case .always: "Always"
    case .never: "Never"
    }
  }

  public var subtitle: String {
    switch self {
    case .busy: "Confirm only when the tab has work that closing would interrupt."
    case .always: "Always confirm before closing a tab."
    case .never: "Close tabs immediately without confirmation."
    }
  }
}
