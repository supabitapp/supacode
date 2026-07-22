import Foundation
import SupacodeSettingsShared

struct TerminalTabItem: Identifiable, Equatable, Sendable {
  let id: TerminalTabID
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
    title: String,
    customTitle: String? = nil,
    icon: String?,
    isTitleLocked: Bool = false,
    tintColor: RepositoryColor? = nil,
    isBlockingScript: Bool = false,
    isBlockingScriptCompleted: Bool = false
  ) {
    self.id = id
    self.title = title
    self.customTitle = customTitle
    self.icon = icon
    self.isTitleLocked = isTitleLocked
    self.tintColor = tintColor
    self.isBlockingScript = isBlockingScript
    self.isBlockingScriptCompleted = isBlockingScriptCompleted
  }
}
