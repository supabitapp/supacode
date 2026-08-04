import Sharing
import SwiftUI

/// Bottom-of-sidebar card announcing the file explorer inspector, marked Beta.
/// Pure FYI: no toggle, no opt-in. Visible until the user dismisses past the
/// relevance cutoff. The priority host (`SidebarBottomCardView`) owns the
/// AppStorage read so SwiftUI re-renders at that layer on dismiss.
struct FileExplorerBetaCardView: View {
  /// Bump on each material content change. Users who dismissed before this date
  /// see the prompt again. Anchored to ship day at 00:00 UTC, the earliest
  /// instant any local timezone reaches the ship-day calendar date, so a
  /// dismiss-on-launch-day satisfies `dismissedAt >= relevantSince`.
  static let cardRelevantSinceDate = Date(timeIntervalSince1970: 1_785_801_600)  // 2026-08-04 00:00 UTC.

  static func isDismissed(at dismissedAt: Date) -> Bool {
    SidebarCardRelevance.isDismissed(at: dismissedAt, relevantSince: cardRelevantSinceDate)
  }

  static func resolveMode(dismissedAt: Date) -> Mode {
    Self.isDismissed(at: dismissedAt) ? .hidden : .visible
  }

  var body: some View {
    FileExplorerBetaCardBody()
  }

  enum Mode: Equatable {
    case hidden
    case visible
  }
}

private struct FileExplorerBetaCardBody: View {
  @Shared(.appStorage("fileExplorerBetaOnboardingDismissedAt"))
  private var dismissedAt: Date = .distantPast

  var body: some View {
    SidebarCard(
      onDismiss: { $dismissedAt.withLock { $0 = .now } },
      content: {
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 6) {
            Text("File explorer")
              .font(.subheadline)
              .fontWeight(.semibold)
            BetaBadge()
          }
          Text(description)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      },
      header: {
        Image(systemName: "list.bullet")
          .font(.title2)
          .foregroundStyle(.indigo)
          .accessibilityHidden(true)
      }
    )
  }

  private var description: LocalizedStringKey {
    """
    Browse a worktree's files in the inspector with inline git status. Stage, \
    discard, move, rename, and open them right from the tree.
    """
  }
}

/// Compact tinted "Beta" pill.
private struct BetaBadge: View {
  var body: some View {
    Text("Beta")
      .font(.caption2)
      .fontWeight(.semibold)
      .foregroundStyle(.indigo)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(.indigo.opacity(0.15), in: .capsule)
      .accessibilityLabel("Beta")
  }
}
