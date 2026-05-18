import Sharing
import SwiftUI

/// Bottom-of-sidebar onboarding card announcing zmx-backed session persistence.
/// Pure FYI: no toggle to consult, no opt-in. Visible until the user dismisses
/// past the relevance cutoff. The priority host (`SidebarBottomCardView`) owns
/// the AppStorage read so SwiftUI re-renders at that layer on dismiss.
struct TerminalPersistenceOnboardingCardView: View {
  /// Bump on each material content change. Users who dismissed before this
  /// date see the prompt again. Anchored to ship day at 00:00 UTC, the
  /// earliest instant any local timezone reaches the ship-day calendar date,
  /// so a dismiss-on-launch-day satisfies `dismissedAt >= relevantSince`.
  static let cardRelevantSinceDate = Date(timeIntervalSince1970: 1_779_062_400)  // 2026-05-18 00:00 UTC.

  static func isDismissed(at dismissedAt: Date) -> Bool {
    SidebarCardRelevance.isDismissed(at: dismissedAt, relevantSince: cardRelevantSinceDate)
  }

  static func resolveMode(dismissedAt: Date) -> Mode {
    Self.isDismissed(at: dismissedAt) ? .hidden : .visible
  }

  var body: some View {
    TerminalPersistenceOnboardingCardBody()
  }

  enum Mode: Equatable {
    case hidden
    case visible
  }
}

private struct TerminalPersistenceOnboardingCardBody: View {
  @Shared(.appStorage("terminalPersistenceOnboardingDismissedAt"))
  private var dismissedAt: Date = .distantPast

  var body: some View {
    SidebarCard(
      onDismiss: { $dismissedAt.withLock { $0 = .now } },
      content: {
        VStack(alignment: .leading, spacing: 4) {
          SidebarCardLabel(title: "Sessions persist across quits", description: description)
          Text("Manage in Settings → General")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.top, 2)
        }
      },
      header: {
        Image(systemName: "infinity")
          .font(.title2)
          .foregroundStyle(.purple)
          .accessibilityHidden(true)
      }
    )
  }

  private var description: LocalizedStringKey {
    """
    Quit Supacode anytime. Your agents, scripts, and shells keep running, \
    and reopen exactly where you left off.
    """
  }
}
