import Foundation
import SupacodeSettingsShared

/// Identifies the kind of script that runs in a dedicated terminal tab
/// with exit-code tracking. `.archive` and `.delete` block worktree
/// state transitions until the script completes. `.script` wraps a
/// user-defined `ScriptDefinition` and can run concurrently.
///
/// Equality and hashing for the `.script` case use only the
/// definition's `id`, so dictionary lookups and dedup checks remain
/// stable even when the user edits the script's name or command.
enum BlockingScriptKind: Sendable {
  case script(ScriptDefinition)
  case archive
  case delete

  var tabTitle: String {
    switch self {
    case .script(let definition): definition.displayName
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

  /// `true` when this is a `.run`-kind script — the only kind
  /// stopped by the global Stop action (Cmd+.), since Stop is
  /// the semantic counterpart of Run.
  var isRunKind: Bool {
    switch self {
    case .script(let definition): definition.kind == .run
    case .archive, .delete: false
    }
  }
}

// MARK: - Hashable / Equatable

extension BlockingScriptKind: Hashable {
  static func == (lhs: BlockingScriptKind, rhs: BlockingScriptKind) -> Bool {
    switch (lhs, rhs) {
    case (.script(let lhsDef), .script(let rhsDef)): lhsDef.id == rhsDef.id
    case (.archive, .archive): true
    case (.delete, .delete): true
    default: false
    }
  }

  func hash(into hasher: inout Hasher) {
    switch self {
    case .script(let definition):
      hasher.combine(0)
      hasher.combine(definition.id)
    case .archive:
      hasher.combine(1)
    case .delete:
      hasher.combine(2)
    }
  }
}
