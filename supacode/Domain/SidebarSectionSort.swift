/// View-menu sort for sidebar folder and repository sections.
///
/// Stored as its raw string in AppStorage (`sidebarSectionSort`) so a new
/// mode is another case, not another boolean. Display order is applied on
/// top of the persisted `sidebar.sections` drag order and never rewrites it.
nonisolated enum SidebarSectionSort: String, CaseIterable, Equatable, Hashable,
  Identifiable, Sendable
{
  /// Persisted drag order (`sidebar.sections` key order).
  case manual
  /// A-Z by sidebar display name.
  case alphabetical

  static let `default` = SidebarSectionSort.manual

  var id: String { rawValue }

  var menuTitle: String {
    switch self {
    case .manual: "Manual Order"
    case .alphabetical: "By Name"
    }
  }

  /// Comparator for a sorted display overlay, `nil` for persisted order. Single
  /// source of truth so `allowsReordering` can never disagree with `ordered` and
  /// corrupt persisted order via a stale `.onMove` offset. Any comparator must
  /// be a strict weak ordering, else `sorted` traps.
  private var displayComparator: ((String, Repository.ID, String, Repository.ID) -> Bool)? {
    switch self {
    case .manual: nil
    case .alphabetical: Repository.sidebarNameOrdersBefore
    }
  }

  /// Whether the sidebar list may drag-reorder sections. A sorted overlay
  /// leaves the persisted key list untouched, so drag is off.
  var allowsReordering: Bool { displayComparator == nil }

  /// Reorder `ids` for display. Identity for `.manual`; otherwise sorts by
  /// `name` through the mode's comparator.
  func ordered(
    _ ids: [Repository.ID],
    name: (Repository.ID) -> String
  ) -> [Repository.ID] {
    guard let comparator = displayComparator else { return ids }
    // Memoize so each id's display name is resolved once on first reach, not
    // the O(n log n) times a per-comparison `name` call would repeat its lookups.
    var resolved: [Repository.ID: String] = [:]
    resolved.reserveCapacity(ids.count)
    func displayName(for id: Repository.ID) -> String {
      if let cached = resolved[id] { return cached }
      let value = name(id)
      resolved[id] = value
      return value
    }
    return ids.sorted { comparator(displayName(for: $0), $0, displayName(for: $1), $1) }
  }
}
