import Sharing
import SwiftUI

/// Bottom-of-sidebar card announcing the reworked pane layout: window mode,
/// multiple tabs per split, and the improved tab drag and drop. Pure FYI: no
/// toggle, no opt-in. Visible until the user dismisses past the relevance
/// cutoff. The priority host (`SidebarBottomCardView`) owns the AppStorage read
/// so SwiftUI re-renders at that layer on dismiss.
struct LayoutModesCardView: View {
  /// Bump on each material content change. Users who dismissed before this date
  /// see the prompt again. Anchored to ship day at 00:00 UTC, the earliest
  /// instant any local timezone reaches the ship-day calendar date, so a
  /// dismiss-on-launch-day satisfies `dismissedAt >= relevantSince`.
  static let cardRelevantSinceDate = Date(timeIntervalSince1970: 1_786_320_000)  // 2026-08-10 00:00 UTC.

  static func isDismissed(at dismissedAt: Date) -> Bool {
    SidebarCardRelevance.isDismissed(at: dismissedAt, relevantSince: cardRelevantSinceDate)
  }

  static func resolveMode(dismissedAt: Date) -> Mode {
    Self.isDismissed(at: dismissedAt) ? .hidden : .visible
  }

  var body: some View {
    LayoutModesCardBody()
  }

  enum Mode: Equatable {
    case hidden
    case visible
  }
}

private struct LayoutModesCardBody: View {
  @Shared(.appStorage("layoutModesOnboardingDismissedAt"))
  private var dismissedAt: Date = .distantPast

  var body: some View {
    SidebarCard(
      onDismiss: { $dismissedAt.withLock { $0 = .now } },
      content: {
        SidebarCardLabel(title: "New layout", description: description)
      },
      header: {
        Image(systemName: "rectangle.split.2x1")
          .font(.title2)
          .foregroundStyle(.teal)
          .accessibilityHidden(true)
      }
    )
  }

  private var description: LocalizedStringKey {
    """
    Give each split its own tabs, pop any pane into its own window, and drag \
    tabs between panes to rearrange everything.
    """
  }
}
