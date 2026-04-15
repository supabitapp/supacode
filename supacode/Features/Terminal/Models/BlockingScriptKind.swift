import Foundation
import SupacodeSettingsShared

/// Identifies the kind of script that runs in a dedicated terminal tab
/// with exit-code tracking. `.archive` and `.delete` block worktree
/// state transitions until the script completes. `.script` wraps a
/// user-defined `ScriptDefinition` and can run concurrently.
enum BlockingScriptKind: Hashable, Sendable {
  case script(ScriptDefinition)
  case archive
  case delete

  var tabTitle: String {
    switch self {
    case .script(let definition): definition.name
    case .archive: "Archive Script"
    case .delete: "Delete Script"
    }
  }

  var tabIcon: String {
    switch self {
    case .script(let definition): definition.resolvedSystemImage
    case .archive: "archivebox.fill"
    case .delete: "trash.fill"
    }
  }

  var tabColor: TerminalTabTintColor {
    switch self {
    case .script(let definition): definition.resolvedTintColor
    case .archive: .orange
    case .delete: .red
    }
  }

  /// The script definition ID for user-defined scripts, `nil` for lifecycle scripts.
  var scriptDefinitionID: UUID? {
    switch self {
    case .script(let definition): definition.id
    case .archive, .delete: nil
    }
  }

  /// `true` when this is a `.run`-kind script — the only kind stopped by Cmd+.
  var isRunKind: Bool {
    switch self {
    case .script(let definition): definition.kind == .run
    case .archive, .delete: false
    }
  }
}
