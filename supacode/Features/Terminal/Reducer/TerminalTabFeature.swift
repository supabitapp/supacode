import ComposableArchitecture
import Foundation
import GhosttyKit

/// Per-tab observable state mirroring the sidebar's per-row `SidebarItemFeature`.
/// Leaves scope through `store.scope(state: \.terminalTabs[id:], action: \.terminalTabs[id:])`
/// so a mutation on tab B only invalidates tab B's leaf.
@Reducer
struct TerminalTabFeature {
  @ObservableState
  struct State: Identifiable, Equatable, Sendable {
    /// Typed `TerminalTabID` so the nominal-type wall against an unrelated
    /// raw `UUID` reaches every scoping site. `IdentifiedArrayOf` keys by
    /// this id directly.
    let id: TerminalTabID
    let worktreeID: Worktree.ID

    /// Surface IDs in this tab in split-tree order. Mirrored from
    /// `WorktreeTerminalState`'s `onTabProjectionChanged`.
    var surfaceIDs: [UUID] = []
    /// Ghostty progress or a blocking script is active in this tab.
    var hasTerminalActivity = false
    /// Focused pane in this tab. Drives the stripe-progress's per-tab source
    /// (focused tab → focused surface; non-focused → worst-of aggregate).
    var activeSurfaceID: UUID?
    /// Count of unread notifications scoped to this tab's surfaces.
    var unseenNotificationCount: Int = 0
    /// True when the tab's split tree has a zoomed pane. The tab-bar leaf swaps
    /// its close button for a dismiss-zoom button while this is set.
    var isSplitZoomed: Bool = false
    /// Monotonic invalidation token for same-UUID surface view replacement.
    var surfaceGeneration = 0
    /// True while the tab's surfaces are hibernated. Drives the tab-bar sleep accessory.
    var isDormant: Bool = false
    /// Per-tab agent snapshot pushed by `AppFeature.agentPresenceFanOutEffect`.
    /// `isWorking` remains populated when badges are disabled, so shimmer is
    /// independent of badge visibility.
    var agentSnapshot: AgentPresenceFeature.RowSnapshot = .init()
    var agents: [AgentPresenceFeature.AgentInstance] { agentSnapshot.agents }
    var hasAgentActivity: Bool { agentSnapshot.isWorking }
    /// Stripe-progress summary. Computed from the active surface's
    /// `GhosttySurfaceState.progressState` (focused tabs) or worst-of-all
    /// surfaces (unfocused tabs). Nil = no progress to display.
    var progressDisplay: TerminalTabProgressDisplay?

    var hasUnseenNotifications: Bool { unseenNotificationCount > 0 }

    func shouldShimmer(isLifecycleRepresentative: Bool) -> Bool {
      hasTerminalActivity || hasAgentActivity || isLifecycleRepresentative
    }
  }

  enum Action: Equatable, Sendable {
    case projectionChanged(WorktreeTabProjection)
    case agentSnapshotChanged(AgentPresenceFeature.RowSnapshot)
    case progressDisplayChanged(TerminalTabProgressDisplay?)
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .projectionChanged(let projection):
        if state.surfaceIDs != projection.surfaceIDs { state.surfaceIDs = projection.surfaceIDs }
        if state.hasTerminalActivity != projection.hasTerminalActivity {
          state.hasTerminalActivity = projection.hasTerminalActivity
        }
        if state.activeSurfaceID != projection.activeSurfaceID {
          state.activeSurfaceID = projection.activeSurfaceID
        }
        if state.unseenNotificationCount != projection.unseenNotificationCount {
          state.unseenNotificationCount = projection.unseenNotificationCount
        }
        if state.isSplitZoomed != projection.isSplitZoomed {
          state.isSplitZoomed = projection.isSplitZoomed
        }
        if state.surfaceGeneration != projection.surfaceGeneration {
          state.surfaceGeneration = projection.surfaceGeneration
        }
        if state.isDormant != projection.isDormant {
          state.isDormant = projection.isDormant
        }
        return .none

      case .agentSnapshotChanged(let snapshot):
        guard state.agentSnapshot != snapshot else { return .none }
        state.agentSnapshot = snapshot
        return .none

      case .progressDisplayChanged(let display):
        guard state.progressDisplay != display else { return .none }
        state.progressDisplay = display
        return .none
      }
    }
  }
}

/// Stripe-progress visualization payload. Per-tab summary of underlying
/// `GhosttySurfaceState.progressState` so the tab-bar stripe stays in lock-step
/// with the tab's focus state.
struct TerminalTabProgressDisplay: Equatable, Sendable {
  enum Style: Equatable, Sendable {
    case error
    case paused
    case indeterminate
    case determinate(percent: Int)
  }

  let style: Style
  /// Accessibility value spoken alongside the tab title ("Busy", "Errored",
  /// "Paused", "47 percent complete"). Read from `TerminalTabView.accessibilityValue`.
  var accessibilityValue: String {
    switch style {
    case .error: return "Errored"
    case .paused: return "Paused"
    case .indeterminate: return "Busy"
    case .determinate(let percent): return "\(percent) percent complete"
    }
  }
}

extension TerminalTabProgressDisplay {
  /// Project a Ghostty per-surface progress payload into the per-tab style.
  /// Returns nil for the REMOVE state and for nil input (no progress in flight).
  static func make(
    progressState: ghostty_action_progress_report_state_e?,
    progressValue: Int?
  ) -> TerminalTabProgressDisplay? {
    guard let progressState, progressState != GHOSTTY_PROGRESS_STATE_REMOVE else { return nil }
    let style: Style
    switch progressState {
    case GHOSTTY_PROGRESS_STATE_ERROR: style = .error
    case GHOSTTY_PROGRESS_STATE_PAUSE: style = .paused
    case GHOSTTY_PROGRESS_STATE_INDETERMINATE: style = .indeterminate
    default:
      if let percent = progressValue {
        style = .determinate(percent: Self.bucketedPercent(percent))
      } else {
        style = .indeterminate
      }
    }
    return TerminalTabProgressDisplay(style: style)
  }

  /// Snap mid-run percents to 5% steps so a 0->100 sweep yields ~20 distinct
  /// displays instead of ~100, collapsing per-percent store dispatches and
  /// stripe repaints at the existing equality gates. 0 and the >=100 terminus
  /// pass through so the bar starts empty and visibly completes.
  private static func bucketedPercent(_ percent: Int) -> Int {
    guard percent > 0 else { return 0 }
    guard percent < 100 else { return 100 }
    return min(95, (percent + 2) / 5 * 5)
  }

  /// Worst-of priority for aggregating across surfaces in an unfocused tab.
  /// Higher rank wins. error > paused > determinate > indeterminate > none.
  var severity: Int {
    switch style {
    case .error: return 4
    case .paused: return 3
    case .determinate: return 2
    case .indeterminate: return 1
    }
  }
}
