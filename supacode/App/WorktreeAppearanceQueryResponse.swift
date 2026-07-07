import SupacodeSettingsShared

/// Builds the `supacode worktree appearance` read payload. Reports stored
/// override fields separately from the resolved display title so a cleared
/// override reads as `title=` rather than the default.
enum WorktreeAppearanceQueryResponse {
  /// Socket wire keys. `WorktreeCommand.Appearance` reads the same literals;
  /// keep both sides in sync (the CLI stays dependency-light, so no shared module).
  enum Key {
    static let title = "title"
    static let color = "color"
    static let displayTitle = "displayTitle"
  }

  static func fields(
    repository: Repository,
    worktree: Worktree,
    item: SidebarState.Item?
  ) -> [String: String] {
    // Use the row's base title (`item.title` ?? worktree / repo name), not the
    // folder-derived disambiguator that `resolvedSidebarTitle` would report.
    let fallbackTitle = repository.isGitRepository ? worktree.name : repository.name
    return [
      Key.title: item?.title ?? "",
      Key.color: item?.color?.rawValue ?? "none",
      Key.displayTitle: SidebarDisplayName.resolved(custom: item?.title, fallback: fallbackTitle) ?? fallbackTitle,
    ]
  }
}
