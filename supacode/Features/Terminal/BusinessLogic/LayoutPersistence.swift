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
        let live = runtime.content(for: contentID)
        if let live {
          overlaid.panes[paneIndex].tabs[tabIndex].content = live.snapshot()
          // Reported titles never enter the layout reducer, so while the content
          // is live the saved record pulls its latest one here.
          overlaid.panes[paneIndex].tabs[tabIndex].title = TabTitle.stored(
            for: overlaid.panes[paneIndex].tabs[tabIndex],
            chrome: live.chrome
          )
        }
        guard case .terminal(let state) = overlaid.panes[paneIndex].tabs[tabIndex].content.state
        else { continue }
        // The presence map is authoritative for live content: absence must
        // CLEAR a stale stored record, not preserve it. Dormant content keeps
        // its stored records unless the map still carries fresher ones.
        let mapped = agentsBySurface[contentID.rawValue].flatMap { $0.isEmpty ? nil : $0 }
        let agents = live != nil ? mapped : mapped ?? state.agents
        guard agents != state.agents else { continue }
        overlaid.panes[paneIndex].tabs[tabIndex].content = ContentSnapshot(
          id: contentID,
          state: .terminal(
            TerminalContentState(
              workingDirectory: state.workingDirectory,
              agents: agents,
              frozenGrid: state.frozenGrid,
              launch: state.launch
            )
          )
        )
      }
    }
    var stripped = overlaid.strippingEphemeralContent()
    // Live-only fields never encode; clear them so the record equals its
    // decoded round-trip and the writer's no-op gate can hold.
    for paneIndex in stripped.panes.indices {
      for tabIndex in stripped.panes[paneIndex].tabs.indices {
        stripped.panes[paneIndex].tabs[tabIndex].isLocked = false
        guard case .terminal(let state) = stripped.panes[paneIndex].tabs[tabIndex].content.state,
          state.launch != nil
        else { continue }
        stripped.panes[paneIndex].tabs[tabIndex].content = ContentSnapshot(
          id: stripped.panes[paneIndex].tabs[tabIndex].content.id,
          state: .terminal(
            TerminalContentState(
              workingDirectory: state.workingDirectory,
              agents: state.agents,
              frozenGrid: state.frozenGrid
            )
          )
        )
      }
    }
    return LayoutRecord(layout: stripped, origin: origin)
  }
}
