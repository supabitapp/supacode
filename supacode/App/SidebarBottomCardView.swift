import ComposableArchitecture
import Sharing
import SwiftUI

/// Mutually-exclusive host for the pinned sidebar bottom card. Priority order:
/// 1. Coding-agent updates available / initial install prompt
///    (`CodingAgentsSidebarCardView`).
/// 2. Nested-worktrees onboarding prompt (`NestedWorktreesOnboardingCardView`).
/// 3. Nothing.
///
/// Owns the `@Shared(.appStorage)` reads as stored properties so SwiftUI
/// observes them at this layer and re-renders when the user dismisses a
/// card or toggles grouping off via the View menu. Each downstream card's
/// `resolveMode(...)` takes the resolved values as parameters so they stay
/// pure (no hidden global reads inside a static).
///
/// Toggling grouping off via the View menu also permanently dismisses the
/// onboarding card, so re-enabling grouping later doesn't bring the prompt
/// back. Friction is intentional: the menu is the single source of truth
/// for opting out, and a user who's already opted out has by definition
/// seen where the option lives.
struct SidebarBottomCardView: View {
  let store: StoreOf<AppFeature>
  @Shared(.appStorage("codingAgentsSetupCardDismissedAt"))
  private var agentDismissedAt: Date = .distantPast
  @Shared(.appStorage("sidebarNestWorktreesByBranch"))
  private var nestWorktreesByBranch = true
  @Shared(.appStorage("nestedWorktreesOnboardingDismissedAt"))
  private var onboardingDismissedAt: Date = .distantPast

  var body: some View {
    let agentMode = CodingAgentsSidebarCardView.resolveMode(
      for: store, dismissedAt: agentDismissedAt
    )
    let onboardingMode = NestedWorktreesOnboardingCardView.resolveMode(
      nestWorktreesByBranch: nestWorktreesByBranch,
      dismissedAt: onboardingDismissedAt
    )
    let resolved = ResolvedCard.resolve(agentMode: agentMode, onboardingMode: onboardingMode)
    Group {
      switch resolved {
      case .none:
        EmptyView()
      case .agent(let mode):
        CodingAgentsSidebarCardView(store: store, mode: mode)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      case .nestedWorktreesOnboarding:
        NestedWorktreesOnboardingCardView()
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: resolved.transitionToken)
    .onChange(of: nestWorktreesByBranch) { _, newValue in
      // Toggling grouping off counts as permanent dismissal of the onboarding
      // card, so the card doesn't re-appear when the user later turns grouping
      // back on. No-op when already past the relevance cutoff.
      guard !newValue else { return }
      guard !NestedWorktreesOnboardingCardView.isDismissed(at: onboardingDismissedAt) else { return }
      $onboardingDismissedAt.withLock { $0 = .now }
    }
  }
}

/// Resolution layer between live state and the rendered branch. Pure so tests
/// can lock the priority rules and `transitionToken` stability without
/// exercising the SwiftUI rendering path.
enum ResolvedCard: Equatable {
  case none
  case agent(CodingAgentsSidebarCardView.Mode)
  case nestedWorktreesOnboarding

  static func resolve(
    agentMode: CodingAgentsSidebarCardView.Mode,
    onboardingMode: NestedWorktreesOnboardingCardView.Mode
  ) -> ResolvedCard {
    switch agentMode {
    case .updatesAvailable, .promptInstall:
      return .agent(agentMode)
    case .hidden:
      break
    }
    return onboardingMode == .visible ? .nestedWorktreesOnboarding : .none
  }

  /// Hashable identity used by `.animation(_:value:)`. Same-variant state
  /// changes share a token so the entry transition only fires when the
  /// rendered branch actually changes. The `agent.hidden` variant is
  /// unreachable here (`resolve` collapses it to `.none`), so it isn't
  /// enumerated.
  var transitionToken: String {
    switch self {
    case .none: "none"
    case .agent(.updatesAvailable(let agents)):
      "agent:updates:" + agents.map(\.rawValue).sorted().joined(separator: ",")
    case .agent(.promptInstall): "agent:promptInstall"
    case .agent(.hidden): "agent:hidden"  // unreachable; present so the switch stays exhaustive.
    case .nestedWorktreesOnboarding: "nestedWorktrees:visible"
    }
  }
}
