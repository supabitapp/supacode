import SupacodeSettingsShared

/// Constructs the socket payload for `supacode worktree appearance` reads.
///
/// The CLI intentionally reports stored override fields separately from the
/// app-resolved display title so clearing an override is visible as `title=`
/// rather than looking like the default title is still stored.
enum WorktreeAppearanceQueryResponse {
  /// `resolvedSidebarTitle` is the seeded row's rendered title
  /// (`SidebarItemFeature.State.resolvedSidebarTitle`); it wins so
  /// `displayTitle` matches what the sidebar actually shows. The
  /// override-based fallback only covers rows not yet seeded.
  static func fields(
    repository: Repository,
    worktree: Worktree,
    item: SidebarState.Item?,
    resolvedSidebarTitle: String?
  ) -> [String: String] {
    let fallbackTitle = repository.isGitRepository ? worktree.name : repository.name
    return [
      "title": item?.title ?? "",
      "color": item?.color?.rawValue ?? "none",
      "displayTitle": resolvedSidebarTitle
        ?? SidebarDisplayName.resolved(custom: item?.title, fallback: fallbackTitle)
        ?? fallbackTitle,
    ]
  }
}
