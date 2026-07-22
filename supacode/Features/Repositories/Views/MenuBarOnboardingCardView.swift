import Sharing
import SwiftUI

/// Bottom-of-sidebar onboarding card announcing that Supacode now lives in the
/// menu bar by default, and pointing to where to turn it off. Renders while the
/// menu bar icon is showing and the user hasn't dismissed past the relevance
/// cutoff; the priority host (`SidebarBottomCardView`) owns the AppStorage read
/// so SwiftUI re-renders at that layer on dismiss.
struct MenuBarOnboardingCardView: View {
  /// Bump on each material content change. Users who dismissed before this date
  /// see the prompt again. Must be on or before the ship date so a dismiss on
  /// release day satisfies `dismissedAt >= relevantSince` and the card stays
  /// hidden.
  static let cardRelevantSinceDate = Date(timeIntervalSince1970: 1_784_678_400)  // 2026-07-22 00:00 UTC.

  static func isDismissed(at dismissedAt: Date) -> Bool {
    SidebarCardRelevance.isDismissed(at: dismissedAt, relevantSince: cardRelevantSinceDate)
  }

  /// Pure resolver. Visible while the menu bar icon is showing and the user
  /// hasn't dismissed past the relevance cutoff. Turning the menu bar off in
  /// Settings clears `showsMenuBarIcon`, so the card retires on its own.
  static func resolveMode(showsMenuBarIcon: Bool, dismissedAt: Date) -> Mode {
    showsMenuBarIcon && !Self.isDismissed(at: dismissedAt) ? .visible : .hidden
  }

  var body: some View {
    MenuBarOnboardingCardBody()
  }

  enum Mode: Equatable {
    case hidden
    case visible
  }
}

private struct MenuBarOnboardingCardBody: View {
  @Shared(.appStorage("menuBarOnboardingDismissedAt"))
  private var dismissedAt: Date = .distantPast

  var body: some View {
    SidebarCard(
      onDismiss: { $dismissedAt.withLock { $0 = .now } },
      content: {
        VStack(alignment: .leading, spacing: 4) {
          SidebarCardLabel(title: "Supacode in the menu bar", description: description)
          Text("Turn off in Settings → General")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.top, 2)
        }
      },
      header: {
        Image(systemName: "menubar.rectangle")
          .font(.title2)
          .foregroundStyle(.green)
          .accessibilityHidden(true)
      }
    )
  }

  private var description: LocalizedStringKey {
    """
    Supacode now lives in your menu bar, so notifications and worktrees stay one \
    click away even when the window is closed.
    """
  }
}
