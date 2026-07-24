import Foundation
import SupacodeSettingsShared

struct TerminalTabItem: Identifiable, Equatable, Sendable {
  /// What the tab renders. `.terminal` tabs own a split tree of Ghostty
  /// surfaces; `.scratchpad` tabs render a plain-text editor and have no
  /// surfaces at all. Raw `String` so layout snapshots persist it stably.
  enum Kind: String, Equatable, Sendable, Codable {
    case terminal
    case scratchpad
  }

  let id: TerminalTabID
  /// Immutable for the tab's lifetime: a tab never changes what it renders.
  let kind: Kind
  /// Live shell title; for display use `displayTitle`.
  var title: String
  /// User-supplied override; nil means follow the live shell title.
  var customTitle: String?
  var icon: String?
  var isTitleLocked: Bool
  var tintColor: RepositoryColor?
  /// Sticky marker for tabs born from `runBlockingScript`; stays true after
  /// completion so guardrails outlive the script (these tabs die with the app).
  var isBlockingScript: Bool
  /// Flips true once `markBlockingScriptCompleted` runs. Distinguishes "running"
  /// from "frozen" so the view can show the lock indicator only post-completion.
  var isBlockingScriptCompleted: Bool

  var displayTitle: String { customTitle ?? title }

  init(
    id: TerminalTabID = TerminalTabID(),
    kind: Kind = .terminal,
    title: String,
    customTitle: String? = nil,
    icon: String?,
    isTitleLocked: Bool = false,
    tintColor: RepositoryColor? = nil,
    isBlockingScript: Bool = false,
    isBlockingScriptCompleted: Bool = false
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.customTitle = customTitle
    self.icon = icon
    self.isTitleLocked = isTitleLocked
    self.tintColor = tintColor
    self.isBlockingScript = isBlockingScript
    self.isBlockingScriptCompleted = isBlockingScriptCompleted
  }
}
