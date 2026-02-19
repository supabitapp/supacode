import SwiftUI

struct WorktreeDiffPanelView: View {
  let state: RepositoriesFeature.WorktreeDiffPanelState
  let selectedWorktreeID: Worktree.ID
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let isSelectedWorktreeState = state.worktreeID == selectedWorktreeID
    let patch = isSelectedWorktreeState ? state.patch : nil
    Group {
      if let patch, !patch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        PierreDiffWebView(
          patch: patch,
          theme: colorScheme == .dark ? .dark : .light
        )
        .overlay(alignment: .topTrailing) {
          if state.isLoading && isSelectedWorktreeState {
            ProgressView()
              .controlSize(.small)
              .padding(8)
          }
        }
      } else if state.isLoading || !isSelectedWorktreeState {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let errorMessage = state.errorMessage, isSelectedWorktreeState {
        ContentUnavailableView(
          "Unable to Load Diff",
          systemImage: "exclamationmark.triangle",
          description: Text(errorMessage)
        )
      } else {
        ContentUnavailableView(
          "No Changes",
          systemImage: "checkmark.circle",
          description: Text("Working tree is clean.")
        )
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
