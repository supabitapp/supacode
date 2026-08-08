import Foundation
import IdentifiedCollections
import SupacodeSettingsShared

/// Turns live layout state into the record persisted to `layouts.json`,
/// overlaying each tab's snapshot with the runtime's live content so the saved
/// frozen grid is always the last one actually applied.
@MainActor
enum LayoutPersistence {
  /// A record whose every tab reflects the live content's current snapshot;
  /// hibernated or absent contents keep their stored snapshot untouched.
  /// Live agent badge records overlay per content so they survive relaunch.
  static func record(
    for layout: PaneLayout,
    origin: TerminalLayoutSnapshot? = nil,
    runtime: ContentRuntime,
    agentsBySurface: [UUID: [TerminalLayoutSnapshot.SurfaceAgentRecord]] = [:]
  ) -> LayoutRecord {
    var overlaid = layout
    for paneIndex in overlaid.panes.indices {
      for tabIndex in overlaid.panes[paneIndex].tabs.indices {
        let contentID = overlaid.panes[paneIndex].tabs[tabIndex].content.id
        if let live = runtime.content(for: contentID) {
          overlaid.panes[paneIndex].tabs[tabIndex].content = live.snapshot()
        }
        guard let agents = agentsBySurface[contentID.rawValue],
          case .terminal(let state) = overlaid.panes[paneIndex].tabs[tabIndex].content.state
        else { continue }
        overlaid.panes[paneIndex].tabs[tabIndex].content = ContentSnapshot(
          id: contentID,
          state: .terminal(
            TerminalContentState(
              workingDirectory: state.workingDirectory,
              agents: agents.isEmpty ? nil : agents,
              frozenGrid: state.frozenGrid,
              launch: state.launch
            )
          )
        )
      }
    }
    return LayoutRecord(layout: overlaid.strippingEphemeralContent(), origin: origin)
  }
}
