import Foundation
import SupacodeSettingsShared

struct PendingWorktree: Identifiable, Hashable {
  /// Sidebar customization that travels with the in-flight creation. Reconcile
  /// reads this when materializing the pending row so a user-typed title /
  /// color is visible while the worktree is being created; on success the
  /// reducer copies it into the bucketed `SidebarState.Item` before the next
  /// reconcile, on failure it's dropped with the row.
  struct Customization: Hashable {
    let title: String?
    let color: RepositoryColor?
  }

  let id: String
  let repositoryID: Repository.ID
  var progress: WorktreeCreationProgress
  var customization: Customization?

  init(
    id: String,
    repositoryID: Repository.ID,
    progress: WorktreeCreationProgress,
    customization: Customization? = nil
  ) {
    self.id = id
    self.repositoryID = repositoryID
    self.progress = progress
    self.customization = customization
  }
}
