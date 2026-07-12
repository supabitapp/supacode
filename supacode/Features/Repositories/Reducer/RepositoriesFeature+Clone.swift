import ComposableArchitecture
import Foundation
import Sharing

extension RepositoriesFeature {
  /// Dedicated reducer for the clone form, split out so its `ifLet` child reducer
  /// runs before the delegate handler nils the presented state.
  static var cloneRepositoryFormReducer: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .requestCloneRepository:
        @Shared(.appStorage("lastCloneLocationPath")) var lastCloneLocationPath = ""
        // Seed with the last-used parent so a burst of clones doesn't re-pick the
        // folder each time; fall back to home on first run.
        let seededLocation =
          lastCloneLocationPath.isEmpty
          ? FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
          : lastCloneLocationPath
        state.cloneRepositoryForm = CloneRepositoryFormFeature.State(cloneLocationPath: seededLocation)
        return .none

      case .cloneRepositoryForm(.presented(.delegate(.cancel))):
        state.cloneRepositoryForm = nil
        return .none

      case .cloneRepositoryForm(.presented(.delegate(.cloned(let directory)))):
        @Shared(.appStorage("lastCloneLocationPath")) var lastCloneLocationPath = ""
        // Drop the directory URL's trailing slash so the remembered parent matches
        // the slash-free format the folder picker writes.
        var parent = directory.deletingLastPathComponent().path(percentEncoded: false)
        if parent.count > 1, parent.hasSuffix("/") {
          parent.removeLast()
        }
        $lastCloneLocationPath.withLock { $0 = parent }
        state.cloneRepositoryForm = nil
        // Register the cloned directory through the standard open path so it is
        // resolved, persisted, and loaded exactly like a picked folder.
        return .send(.openRepositories([directory]))

      default:
        return .none
      }
    }
  }
}
