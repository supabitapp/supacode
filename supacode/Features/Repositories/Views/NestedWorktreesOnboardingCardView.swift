import Sharing
import SwiftUI

/// Pinned bottom-of-sidebar onboarding card surfacing the new branch-nesting
/// default. Shows while nesting is on and the user hasn't already dismissed;
/// hides as soon as either side flips. The priority host
/// (`SidebarBottomCardView`) owns both AppStorage reads so SwiftUI re-renders
/// at this layer when state changes.
///
/// No inline disable action by design: the menu is the single source of
/// truth for the toggle, and surfacing the menu location teaches the user
/// where the setting lives.
struct NestedWorktreesOnboardingCardView: View {
  /// Bump to release-day each time the card's content materially changes;
  /// users who dismissed before this date see the prompt again.
  static let cardRelevantSinceDate = Date(timeIntervalSince1970: 1_778_371_200)  // 2026-05-10.

  static func isDismissed(at dismissedAt: Date) -> Bool {
    SidebarCardRelevance.isDismissed(at: dismissedAt, relevantSince: cardRelevantSinceDate)
  }

  /// Pure resolver: visible only while grouping is on and the user hasn't
  /// dismissed past the relevance cutoff. The caller owns the AppStorage
  /// reads, keeping this resolver free of hidden global reads and SwiftUI
  /// re-rendering at the priority-host layer.
  static func resolveMode(nestWorktreesByBranch: Bool, dismissedAt: Date) -> Mode {
    nestWorktreesByBranch && !Self.isDismissed(at: dismissedAt) ? .visible : .hidden
  }

  var body: some View {
    NestedWorktreesOnboardingCardBody()
  }

  enum Mode: Equatable {
    case hidden
    case visible
  }
}

private struct NestedWorktreesOnboardingCardBody: View {
  @Shared(.appStorage("nestedWorktreesOnboardingDismissedAt"))
  private var dismissedAt: Date = .distantPast

  var body: some View {
    SidebarCard(
      onDismiss: { $dismissedAt.withLock { $0 = .now } },
      content: {
        VStack(alignment: .leading, spacing: 4) {
          SidebarCardLabel(title: "Worktrees nested by branch", description: description)
          Text("Toggle in View → Nest Worktrees by Branch")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.top, 2)
        }
      },
      header: {
        Image(systemName: "list.bullet.indent")
          .font(.title2)
          .foregroundStyle(.blue)
          .accessibilityHidden(true)
      }
    )
  }

  private var description: LocalizedStringKey {
    """
    Branches with `/` like `feature/tools/branch` now nest under collapsible groups, \
    sorted alphabetically. Toggle off to restore custom ordering.
    """
  }
}
