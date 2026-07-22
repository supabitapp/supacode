import Foundation
import SupacodeSettingsShared

/// Builds the `supacode worktree list` rows and the `supacode worktree status`
/// row. Both report the same `status` vocabulary.
nonisolated enum WorktreeStatusQueryResponse {
  /// Socket wire keys. Mirrors `WorktreeCommand.Key` (CLI side); keep in sync
  /// (the CLI links no shared module to stay dependency-light).
  enum Key {
    static let id = "id"
    static let focused = "focused"
    static let status = "status"
    static let archived = "archived"
  }

  /// Percent-encoding for IDs printed as a single tab-separated column.
  static let idAllowedCharacters = CharacterSet.urlPathAllowed
    .subtracting(.init(charactersIn: "/"))

  static func encoded(id: String) -> String {
    id.addingPercentEncoding(withAllowedCharacters: idAllowedCharacters) ?? id
  }

  static func listFields(
    worktreeID: Worktree.ID,
    status: SidebarState.WorktreeStatus,
    isFocused: Bool
  ) -> [String: String] {
    var fields = [
      Key.id: encoded(id: worktreeID.rawValue),
      Key.status: status.rawValue,
    ]
    if isFocused {
      fields[Key.focused] = "1"
    }
    return fields
  }

  /// `archived` is reported alongside `status` so scripts can gate on the
  /// hidden/visible split without enumerating every status value.
  static func statusFields(
    status: SidebarState.WorktreeStatus,
    isFocused: Bool
  ) -> [String: String] {
    [
      Key.status: status.rawValue,
      Key.archived: status.isArchived ? "true" : "false",
      Key.focused: isFocused ? "true" : "false",
    ]
  }
}
