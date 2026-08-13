/// View-menu sort for sidebar folder and repository sections.
///
/// Stored as its raw string in AppStorage (`sidebarSectionSort`) so a new
/// mode is another case, not another boolean. Display order is applied on
/// top of the persisted `sidebar.sections` drag order and never rewrites it.
nonisolated enum SidebarSectionSort: String, CaseIterable, Codable, Equatable, Hashable,
  Identifiable, Sendable
{
  /// Persisted drag order (`sidebar.sections` key order).
  case manual
  /// A–Z by sidebar display name.
  case alphabetical

  static let `default` = SidebarSectionSort.manual

  var id: String { rawValue }

  var menuTitle: String {
    switch self {
    case .manual: "Manual Order"
    case .alphabetical: "By Name"
    }
  }

  /// Whether the sidebar list may drag-reorder sections. Sorted modes overlay
  /// display order on the persisted key list, so drag is off.
  var allowsReordering: Bool {
    switch self {
    case .manual: true
    case .alphabetical: false
    }
  }

  /// Reorder `ids` for display. `.manual` is identity; `.alphabetical` uses
  /// `name` plus `Repository.sidebarNameOrdersBefore`.
  func ordered(
    _ ids: [Repository.ID],
    name: (Repository.ID) -> String
  ) -> [Repository.ID] {
    switch self {
    case .manual:
      return ids
    case .alphabetical:
      return ids.sorted { lhs, rhs in
        Repository.sidebarNameOrdersBefore(name(lhs), id: lhs, name(rhs), id: rhs)
      }
    }
  }
}
