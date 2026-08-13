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

  static func worktreeAppearance(worktreeID: String, title: String?, color: String?) -> String {
    var url = "supacode://worktree/\(worktreeID)/appearance"
    var params: [String] = []
    if let title { params.append("title=\(percentEncodeQueryValue(title))") }
    if let color { params.append("color=\(percentEncodeQueryValue(color))") }
    if !params.isEmpty { url += "?\(params.joined(separator: "&"))" }
    return url
  }

  // MARK: - Script.

  static func scriptRun(worktreeID: String, scriptID: String) -> String {
    "supacode://worktree/\(worktreeID)/script/\(scriptID)/run"
  }

  static func scriptStop(worktreeID: String, scriptID: String) -> String {
    "supacode://worktree/\(worktreeID)/script/\(scriptID)/stop"
  }

  // MARK: - Tab.

  static func tabFocus(worktreeID: String, tabID: String) -> String {
    "supacode://worktree/\(worktreeID)/tab/\(tabID)"
  }

  static func tabNew(worktreeID: String, input: String?, id: String?, title: String?, pane: String?) -> String {
    var url = "supacode://worktree/\(worktreeID)/tab/new"
    var params: [String] = []
    if let input { params.append("input=\(percentEncodeQueryValue(input))") }
    if let id { params.append("id=\(id)") }
    if let title { params.append("title=\(percentEncodeQueryValue(title))") }
    if let pane { params.append("pane=\(pane)") }
    if !params.isEmpty { url += "?\(params.joined(separator: "&"))" }
    return url
  }

  static func tabRename(worktreeID: String, tabID: String, title: String) -> String {
    "supacode://worktree/\(worktreeID)/tab/\(tabID)/rename?title=\(percentEncodeQueryValue(title))"
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

  // MARK: - Tab move.

  static func tabMove(worktreeID: String, tabID: String, direction: String) -> String {
    "supacode://worktree/\(worktreeID)/tab/\(tabID)/move?direction=\(direction)"
  }

  // MARK: - Pane.

  static func paneFocus(worktreeID: String, paneID: String) -> String {
    "supacode://worktree/\(worktreeID)/pane/\(paneID)"
  }

  static func paneFocusDirection(worktreeID: String, direction: String) -> String {
    "supacode://worktree/\(worktreeID)/pane/focus?direction=\(direction)"
  }

  struct PaneSplitOptions {
    var direction: String?
    var input: String?
    var id: String?
  }

  static func paneSplit(worktreeID: String, paneToken: String, options: PaneSplitOptions) -> String {
    var url = "supacode://worktree/\(worktreeID)/pane/\(paneToken)/split"
    var params: [String] = []
    if let direction = options.direction { params.append("direction=\(direction)") }
    if let input = options.input { params.append("input=\(percentEncodeQueryValue(input))") }
    if let id = options.id { params.append("id=\(id)") }
    if !params.isEmpty { url += "?\(params.joined(separator: "&"))" }
    return url
  }

  static func paneClose(worktreeID: String, paneToken: String) -> String {
    "supacode://worktree/\(worktreeID)/pane/\(paneToken)/destroy"
  }

  static func paneZoom(worktreeID: String, paneToken: String) -> String {
    "supacode://worktree/\(worktreeID)/pane/\(paneToken)/zoom"
  }

  static func paneWindow(worktreeID: String, paneToken: String) -> String {
    "supacode://worktree/\(worktreeID)/pane/\(paneToken)/window"
  }

  static func paneEqualize(worktreeID: String) -> String {
    "supacode://worktree/\(worktreeID)/pane/equalize"
  }

  // MARK: - Repo.

  static func repoOpen(path: String) -> String {
    "supacode://repo/open?path=\(percentEncodeQueryValue(path))"
  }

  struct WorktreeNewOptions {
    var branch: String?
    var base: String?
    /// Upstream branch for the new branch; empty means "no upstream", `nil`
    /// leaves tracking to Git.
    var upstream: String?
    var fetch: Bool
    var name: String?
    var location: String?
    var pin = false
    /// Opt-in to checking out an existing, unused local branch. Absent means the
    /// creation still refuses a branch name that already exists.
    var reuseExistingBranch = false
  }

  static func repoWorktreeNew(repoID: String, options: WorktreeNewOptions) -> String {
    var url = "supacode://repo/\(repoID)/worktree/new"
    var params: [String] = []
    if let branch = options.branch { params.append("branch=\(percentEncodeQueryValue(branch))") }
    if let base = options.base { params.append("base=\(percentEncodeQueryValue(base))") }
    if let upstream = options.upstream { params.append("upstream=\(percentEncodeQueryValue(upstream))") }
    if options.fetch { params.append("fetch=true") }
    if let name = options.name { params.append("name=\(percentEncodeQueryValue(name))") }
    if let location = options.location { params.append("location=\(percentEncodeQueryValue(location))") }
    if options.pin { params.append("pin=true") }
    if options.reuseExistingBranch { params.append("reuse-existing-branch=true") }
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

  static func settingsRepoScripts(repoID: String) -> String {
    "supacode://settings/repo/\(repoID)/scripts"
  }

  // MARK: - Helpers.

  private static func percentEncodeQueryValue(_ value: String) -> String {
    var allowed = CharacterSet.urlQueryAllowed
    // Remove `&` and `=` so they don't conflict with query separators.
    allowed.remove(charactersIn: "&=")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
  }
}
