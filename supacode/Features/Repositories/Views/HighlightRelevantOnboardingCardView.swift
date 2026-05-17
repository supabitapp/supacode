import Sharing
import SwiftUI

/// Bottom-of-sidebar onboarding card surfacing the new "Highlight Relevant
/// Sidebar Items" feature. Renders while the toggle is on and the user
/// hasn't dismissed past the relevance date; the priority host
/// (`SidebarBottomCardView`) owns the AppStorage reads so SwiftUI re-renders
/// at that layer when state changes.
///
/// Sits above the nested-worktree onboarding card in the priority chain so a
/// fresh install learns about Pinned / Active first.
struct HighlightRelevantOnboardingCardView: View {
  /// Bump on each material content change. Users who dismissed before this
  /// date see the prompt again. Must be on or before the ship date so a
  /// dismiss on the day of release satisfies `dismissedAt >= relevantSince`
  /// and the card stays hidden.
  static let cardRelevantSinceDate = Date(timeIntervalSince1970: 1_778_889_600)  // 2026-05-16.

  static func isDismissed(at dismissedAt: Date) -> Bool {
    SidebarCardRelevance.isDismissed(at: dismissedAt, relevantSince: cardRelevantSinceDate)
  }

  /// Pure resolver. Visible while either grouping toggle is on and the user
  /// hasn't dismissed past the relevance cutoff. The caller owns the
  /// AppStorage reads, keeping this resolver free of hidden global reads and
  /// SwiftUI re-rendering at the priority-host layer.
  static func resolveMode(
    groupPinnedRows: Bool,
    groupActiveRows: Bool,
    dismissedAt: Date
  ) -> Mode {
    let anyOn = groupPinnedRows || groupActiveRows
    return anyOn && !Self.isDismissed(at: dismissedAt) ? .visible : .hidden
  }

  var body: some View {
    HighlightRelevantOnboardingCardBody()
  }

  enum Mode: Equatable {
    case hidden
    case visible
  }
}

private struct HighlightRelevantOnboardingCardBody: View {
  @Shared(.appStorage("highlightRelevantOnboardingDismissedAt"))
  private var dismissedAt: Date = .distantPast

  var body: some View {
    SidebarCard(
      onDismiss: { $dismissedAt.withLock { $0 = .now } },
      content: {
        VStack(alignment: .leading, spacing: 4) {
          SidebarCardLabel(title: "Pinned and Active at a glance", description: description)
          Text("Toggle in View → Group Relevant Sidebar Rows")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.top, 2)
        }
      },
      header: {
        Image(systemName: "sparkles")
          .font(.title2)
          .foregroundStyle(.orange)
          .accessibilityHidden(true)
      }
    )
  }

  private var description: LocalizedStringKey {
    """
    Pinned worktrees float to the top, and rows with unread notifications, \
    agents awaiting input, or running scripts surface in a new Active section.
    """
  }
}
