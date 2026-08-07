import IdentifiedCollections
import SupacodeSettingsShared

/// Turns live layout state into the record persisted to `layouts.json`,
/// overlaying each tab's snapshot with the runtime's live content so the saved
/// frozen grid is always the last one actually applied.
@MainActor
enum LayoutPersistence {
  /// A record whose every tab reflects the live content's current snapshot;
  /// hibernated or absent contents keep their stored snapshot untouched.
  static func record(
    for layout: PaneLayout,
    origin: TerminalLayoutSnapshot? = nil,
    runtime: ContentRuntime
  ) -> LayoutRecord {
    var overlaid = layout
    for paneIndex in overlaid.panes.indices {
      for tabIndex in overlaid.panes[paneIndex].tabs.indices {
        let contentID = overlaid.panes[paneIndex].tabs[tabIndex].content.id
        guard let live = runtime.content(for: contentID) else { continue }
        overlaid.panes[paneIndex].tabs[tabIndex].content = live.snapshot()
      }
    }
    return LayoutRecord(layout: overlaid, origin: origin)
  }
}
