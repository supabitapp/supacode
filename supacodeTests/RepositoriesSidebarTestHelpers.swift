import ComposableArchitecture
import Foundation

@testable import supacode

extension RepositoriesFeature.State {
  /// Test mirror of `syncSidebar`.
  @MainActor
  mutating func reconcileSidebarForTesting() {
    RepositoriesFeature.syncSidebar(&self)
  }
}
