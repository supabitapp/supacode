import Observation

/// Per-surface observable kept off `GhosttySurfaceState` so the Ghostty bridge
/// remains a pure mirror of `ghostty_action_*` payloads.
@MainActor
@Observable
final class SurfaceIndicatorState {
  /// Mirror of `WorktreeSurfaceState.hasUnseenNotification(forSurfaceID:)`.
  var hasUnseenNotification: Bool = false
}
