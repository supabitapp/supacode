/// Identifies the kind of script that blocks a worktree state transition
/// and runs in a dedicated terminal tab. Adding a new case requires handling
/// in `AppFeature`'s `.blockingScriptCompleted` event router.
enum BlockingScriptKind: Hashable, Sendable {
  case archive
  case delete

  var tabTitle: String {
    switch self {
    case .archive: return "ARCHIVE SCRIPT"
    case .delete: return "DELETE SCRIPT"
    }
  }

  var tabIcon: String {
    switch self {
    case .archive: return "archivebox.fill"
    case .delete: return "trash.fill"
    }
  }
}
