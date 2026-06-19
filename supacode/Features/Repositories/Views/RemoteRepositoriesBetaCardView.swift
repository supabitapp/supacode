import Sharing
import SwiftUI

/// Bottom-of-sidebar card announcing the remote SSH repositories feature, marked
/// Beta. Pure FYI: no toggle, no opt-in. Visible until the user dismisses past
/// the relevance cutoff. The priority host (`SidebarBottomCardView`) owns the
/// AppStorage read so SwiftUI re-renders at that layer on dismiss.
struct RemoteRepositoriesBetaCardView: View {
  /// Bump on each material content change. Users who dismissed before this date
  /// see the prompt again. Anchored to ship day at 00:00 UTC, the earliest
  /// instant any local timezone reaches the ship-day calendar date, so a
  /// dismiss-on-launch-day satisfies `dismissedAt >= relevantSince`.
  static let cardRelevantSinceDate = Date(timeIntervalSince1970: 1_781_222_400)  // 2026-06-12 00:00 UTC.

  static func isDismissed(at dismissedAt: Date) -> Bool {
    SidebarCardRelevance.isDismissed(at: dismissedAt, relevantSince: cardRelevantSinceDate)
  }

  static func resolveMode(dismissedAt: Date) -> Mode {
    Self.isDismissed(at: dismissedAt) ? .hidden : .visible
  }

  var body: some View {
    RemoteRepositoriesBetaCardBody()
  }

  enum Mode: Equatable {
    case hidden
    case visible
  }
}

private struct RemoteRepositoriesBetaCardBody: View {
  @Shared(.appStorage("remoteRepositoriesBetaOnboardingDismissedAt"))
  private var dismissedAt: Date = .distantPast

  var body: some View {
    SidebarCard(
      onDismiss: { $dismissedAt.withLock { $0 = .now } },
      content: {
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 6) {
            Text("Remote repositories")
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
        Image(systemName: "wifi")
          .font(.title2)
          .foregroundStyle(.teal)
          .accessibilityHidden(true)
      }
    )
  }

  private var description: LocalizedStringKey {
    """
    Add a repository over SSH. Its git, agents, scripts, and terminal run on the \
    host while Supacode renders locally.
    """
  }
}

/// Compact tinted "Beta" pill.
private struct BetaBadge: View {
  var body: some View {
    Text("Beta")
      .font(.caption2)
      .fontWeight(.semibold)
      .foregroundStyle(.teal)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(.teal.opacity(0.15), in: .capsule)
      .accessibilityLabel("Beta")
  }
}
