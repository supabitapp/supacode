import SupacodeSettingsShared
import SwiftUI

extension WorktreeDetailView {
  /// How much of the selected worktree's terminal area is usable. A worktree
  /// whose directory went missing keeps its open tabs until they close, but
  /// refuses new shells.
  enum TerminalAccess: Equatable {
    case hidden
    case existingTabsOnly
    case full

    init(worktree: Worktree, layout: PaneLayout?) {
      if !worktree.isMissing {
        self = .full
      } else if layout?.panes.isEmpty == false {
        self = .existingTabsOnly
      } else {
        self = .hidden
      }
    }
  }
}

struct MissingWorktreeDetailView: View {
  let worktree: Worktree
  let requestDelete: () -> Void

  var body: some View {
    ContentUnavailableView {
      Label("Working directory missing", systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
    } description: {
      VStack(spacing: 6) {
        Text("Restore the directory to keep working here, or delete this worktree to clean up.")
        Text(worktree.workingDirectory.path(percentEncoded: false))
          .monospaced()
          .textSelection(.enabled)
      }
    } actions: {
      Button("Delete Worktree…", systemImage: "trash", role: .destructive, action: requestDelete)
        .help("Delete this worktree from Supacode.")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct MissingWorktreeBanner: View {
  let worktree: Worktree
  let requestDelete: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Label("Working directory missing", systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .appFont(.callout, weight: .semibold)
        .help("Open terminals keep running. New terminals are disabled until the directory is restored.")
      Text(worktree.workingDirectory.path(percentEncoded: false))
        .appFont(.callout, monospaced: true)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .textSelection(.enabled)
      Spacer(minLength: 0)
      Button("Delete Worktree…", systemImage: "trash", role: .destructive, action: requestDelete)
        .controlSize(.small)
        .help("Delete this worktree from Supacode.")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(.bar)
  }
}
