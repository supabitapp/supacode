import Foundation

/// How aggressively to prompt before quitting Supacode. zmx keeps terminal
/// surfaces alive across quit by default, so the historical "always confirm"
/// behavior is no longer the right default. `.auto` confirms only when
/// in-flight work would actually be lost (running scripts, mid-setup,
/// mid-archive, mid-delete).
///
/// Post-Cancel semantics: in `.auto`, after the user clicks Cancel and the
/// active work finishes, the next Cmd+Q quits immediately without re-prompting.
/// This is by design ("auto" follows actual state, not a recent dismissal);
/// users who want a sticky confirmation should pick `.always`.
public nonisolated enum ConfirmQuitMode: String, Codable, CaseIterable, Sendable {
  case auto
  case always
  case never

  public var label: String {
    switch self {
    case .auto: "Auto"
    case .always: "Always"
    case .never: "Never"
    }
  }

  public var subtitle: String {
    switch self {
    case .auto:
      return "Confirm only when scripts are running or a worktree is being set up, archived, or deleted."
    case .always:
      return "Always confirm before quitting."
    case .never:
      return "Quit immediately without confirmation."
    }
  }
}
