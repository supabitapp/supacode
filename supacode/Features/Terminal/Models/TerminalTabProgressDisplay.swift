import GhosttyKit

/// Stripe-progress visualization payload: a per-tab summary of the content's
/// `GhosttySurfaceState.progressState`.
struct TerminalTabProgressDisplay: Equatable, Sendable {
  enum Style: Equatable, Sendable {
    case error
    case paused
    case indeterminate
    case determinate(percent: Int)
  }

  let style: Style
  /// Accessibility value spoken alongside the tab title ("Busy", "Errored",
  /// "Paused", "47 percent complete").
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
