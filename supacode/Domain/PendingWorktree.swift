import Foundation
import SupacodeSettingsShared

struct PendingWorktree: Identifiable, Hashable {
  /// Sidebar customization that travels with the in-flight creation. Reconcile
  /// reads this when materializing the pending row so a user-typed title /
  /// subtitle / color is visible while the worktree is being created; on success
  /// the reducer copies it into the bucketed `SidebarState.Item` before the next
  /// reconcile, on failure it's dropped with the row.
  struct Customization: Hashable {
    let title: String?
    let subtitle: String?
    let color: RepositoryColor?

    init(title: String? = nil, subtitle: String? = nil, color: RepositoryColor? = nil) {
      self.title = title
      self.subtitle = subtitle
      self.color = color
    }
  }

  let id: Worktree.ID
  let repositoryID: Repository.ID
  var progress: WorktreeCreationProgress
  var customization: Customization?

  init(
    id: Worktree.ID,
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
