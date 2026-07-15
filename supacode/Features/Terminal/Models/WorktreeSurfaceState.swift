import Observation

/// Per-surface observable kept off `GhosttySurfaceState` so the Ghostty bridge
/// remains a pure mirror of `ghostty_action_*` payloads.
@MainActor
@Observable
final class WorktreeSurfaceState {
  /// Outstanding unread notifications for this surface. Decoupled from the
  /// capped notification log: trimming never changes it, only reading or
  /// dismissing does. Drives the sidebar dot, tab badge, and toolbar bell.
  var unseenNotificationCount: Int = 0

  var hasUnseenNotification: Bool { unseenNotificationCount > 0 }
}
