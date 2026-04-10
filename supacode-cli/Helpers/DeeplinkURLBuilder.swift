import Foundation

/// Builds `supacode://` deeplink URLs from structured components.
nonisolated enum DeeplinkURLBuilder {
  // MARK: - General.

  static func open() -> String {
    "supacode://"
  }

  // MARK: - Worktree.

  static func worktreeSelect(worktreeID: String) -> String {
    "supacode://worktree/\(worktreeID)"
  }

  static func worktreeAction(_ action: String, worktreeID: String) -> String {
    "supacode://worktree/\(worktreeID)/\(action)"
  }

  // MARK: - Tab.

  static func tabFocus(worktreeID: String, tabID: String) -> String {
    "supacode://worktree/\(worktreeID)/tab/\(tabID)"
  }

  static func tabNew(worktreeID: String, input: String?, id: String?) -> String {
    var url = "supacode://worktree/\(worktreeID)/tab/new"
    var params: [String] = []
    if let input { params.append("input=\(percentEncodeQueryValue(input))") }
    if let id { params.append("id=\(id)") }
    if !params.isEmpty { url += "?\(params.joined(separator: "&"))" }
    return url
  }

  static func tabClose(worktreeID: String, tabID: String) -> String {
    "supacode://worktree/\(worktreeID)/tab/\(tabID)/destroy"
  }

  // MARK: - Surface.

  static func surfaceFocus(worktreeID: String, tabID: String, surfaceID: String, input: String?) -> String {
    var url = "supacode://worktree/\(worktreeID)/tab/\(tabID)/surface/\(surfaceID)"
    if let input { url += "?input=\(percentEncodeQueryValue(input))" }
    return url
  }

  struct SplitOptions {
    var direction: String?
    var input: String?
    var id: String?
  }

  static func surfaceSplit(
    worktreeID: String,
    tabID: String,
    surfaceID: String,
    options: SplitOptions
  ) -> String {
    var url = "supacode://worktree/\(worktreeID)/tab/\(tabID)/surface/\(surfaceID)/split"
    var params: [String] = []
    if let direction = options.direction { params.append("direction=\(direction)") }
    if let input = options.input { params.append("input=\(percentEncodeQueryValue(input))") }
    if let id = options.id { params.append("id=\(id)") }
    if !params.isEmpty { url += "?\(params.joined(separator: "&"))" }
    return url
  }

  static func surfaceClose(worktreeID: String, tabID: String, surfaceID: String) -> String {
    "supacode://worktree/\(worktreeID)/tab/\(tabID)/surface/\(surfaceID)/destroy"
  }

  // MARK: - Repo.

  static func repoOpen(path: String) -> String {
    "supacode://repo/open?path=\(percentEncodeQueryValue(path))"
  }

  static func repoWorktreeNew(repoID: String, branch: String?, base: String?, fetch: Bool) -> String {
    var url = "supacode://repo/\(repoID)/worktree/new"
    var params: [String] = []
    if let branch { params.append("branch=\(percentEncodeQueryValue(branch))") }
    if let base { params.append("base=\(percentEncodeQueryValue(base))") }
    if fetch { params.append("fetch=true") }
    if !params.isEmpty { url += "?\(params.joined(separator: "&"))" }
    return url
  }

  // MARK: - Settings.

  static func settings(section: String?) -> String {
    guard let section else { return "supacode://settings" }
    return "supacode://settings/\(section)"
  }

  static func settingsRepo(repoID: String) -> String {
    "supacode://settings/repo/\(repoID)"
  }

  // MARK: - Helpers.

  private static func percentEncodeQueryValue(_ value: String) -> String {
    var allowed = CharacterSet.urlQueryAllowed
    // Remove `&` and `=` so they don't conflict with query separators.
    allowed.remove(charactersIn: "&=")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
  }
}
