import Foundation
import SupacodeSettingsShared

/// Builds the `supacode worktree list` payload from the app's in-memory sidebar state.
enum WorktreeListQueryResponse {
  enum Key {
    static let id = "id"
    static let focused = "focused"
    static let visibility = "visibility"
  }

  private static let idAllowedCharacters = CharacterSet.urlPathAllowed
    .subtracting(.init(charactersIn: "/"))

  static func fields(
    repositoryID: Repository.ID,
    worktreeID: Worktree.ID,
    sidebar: SidebarState,
    selectedWorktreeID: Worktree.ID?
  ) -> [String: String] {
    let rawID = worktreeID.rawValue
    let encodedID = rawID.addingPercentEncoding(withAllowedCharacters: idAllowedCharacters) ?? rawID
    var fields = [
      Key.id: encodedID,
      Key.visibility: sidebar.visibility(of: worktreeID, in: repositoryID).rawValue,
    ]
    if worktreeID == selectedWorktreeID {
      fields[Key.focused] = "1"
    }
    return fields
  }
}
