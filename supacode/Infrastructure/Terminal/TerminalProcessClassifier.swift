import Foundation
import GhosttyKit

enum TerminalShellState: String, Codable, Sendable, CaseIterable {
  case idle
  case running
  case waitingForInput
}

enum TerminalProcessCategory: String, Codable, Sendable, CaseIterable {
  case shell
  case editor
  case aiTool
  case pager
  case ssh
  case other
}

enum TerminalProcessClassifier {
  static func displayName(for processName: String) -> String {
    let name = canonicalName(for: processName)
    switch name {
    case "claude":
      return "Claude Code"
    case "codex":
      return "Codex"
    case "aider":
      return "Aider"
    case "gemini":
      return "Gemini"
    case "opencode":
      return "OpenCode"
    default:
      return processName
    }
  }

  static func category(for processName: String) -> TerminalProcessCategory {
    let name = canonicalName(for: processName)

    if shells.contains(name) { return .shell }
    if editors.contains(name) { return .editor }
    if aiTools.contains(name) { return .aiTool }
    if pagers.contains(name) { return .pager }
    if sshTools.contains(name) { return .ssh }

    return .other
  }

  static func shellState(from progressState: ghostty_action_progress_report_state_e?) -> TerminalShellState {
    switch progressState {
    case .some(GHOSTTY_PROGRESS_STATE_SET),
      .some(GHOSTTY_PROGRESS_STATE_INDETERMINATE),
      .some(GHOSTTY_PROGRESS_STATE_PAUSE),
      .some(GHOSTTY_PROGRESS_STATE_ERROR):
      return .running
    default:
      return .idle
    }
  }

  private static func canonicalName(for processName: String) -> String {
    processName
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
  }

  private static let shells: Set<String> = [
    "bash",
    "zsh",
    "fish",
    "sh",
    "dash",
    "ksh",
    "tcsh",
  ]

  private static let editors: Set<String> = [
    "vim",
    "nvim",
    "vi",
    "nano",
    "emacs",
    "hx",
    "helix",
  ]

  private static let aiTools: Set<String> = [
    "claude",
    "codex",
    "aider",
    "gemini",
    "opencode",
  ]

  private static let pagers: Set<String> = [
    "less",
    "more",
    "man",
  ]

  private static let sshTools: Set<String> = [
    "ssh",
    "mosh",
  ]
}

enum TerminalForegroundProcessInference {
  static func infer(fromTitle title: String?, pwd: String?) -> String? {
    let rawTitle = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rawTitle.isEmpty else { return nil }

    // If title is just the working directory, there's nothing to infer.
    if let pwd {
      let trimmedPwd = pwd.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmedPwd.isEmpty, rawTitle == trimmedPwd {
        return nil
      }
    }

    // Heuristic: many apps set window title to "NAME ..." or "... - NAME".
    if rawTitle.localizedCaseInsensitiveContains("vim") { return "vim" }
    if rawTitle.localizedCaseInsensitiveContains("emacs") { return "emacs" }

    // Split on common separators and grab the first plausible token.
    let separators: [Character] = ["-", "|", ":"]
    let firstChunk = rawTitle.split(whereSeparator: { separators.contains($0) }).first.map(String.init) ?? rawTitle
    let candidate = firstChunk
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .split(whereSeparator: \.isWhitespace)
      .first
      .map(String.init)

    guard let candidate else { return nil }
    let token = normalizeToken(candidate)
    guard isPlausibleExecutableToken(token) else { return nil }

    return token
  }

  private static func normalizeToken(_ token: String) -> String {
    var t = token.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.hasPrefix("[") {
      // Common prompt prefix like "[1]" or "[git]".
      if let end = t.firstIndex(of: "]") {
        t = String(t[t.index(after: end)...]).trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }
    return t
  }

  private static func isPlausibleExecutableToken(_ token: String) -> Bool {
    guard !token.isEmpty else { return false }
    if token.contains("/") { return false }
    if token.allSatisfy(\.isNumber) { return false }

    // Basic allowlist for title-driven inference: shells + common interactive tools.
    let category = TerminalProcessClassifier.category(for: token)
    if category != .other { return true }

    // Accept unknown tokens that look like an executable name.
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._+-"))
    return token.unicodeScalars.allSatisfy { allowed.contains($0) }
  }
}
