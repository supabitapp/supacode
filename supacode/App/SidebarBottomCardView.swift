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
/// card. Each downstream card's `resolveMode(...)` takes the resolved values
/// as parameters so they stay pure (no hidden global reads inside a static).
///
/// `nestWorktreesByBranch` is observed here so the visible-card resolver can
/// react to the toggle, but the permadismiss side-effect on toggle-off lives
/// in `SidebarCommands` (where the menu toggle actually fires), so it works
/// regardless of whether the sidebar column is currently visible.
struct SidebarBottomCardView: View {
  let store: StoreOf<AppFeature>
  @Shared(.appStorage("codingAgentsSetupCardDismissedAt"))
  private var agentDismissedAt: Date = .distantPast
  @Shared(.sidebarNestWorktreesByBranch) private var nestWorktreesByBranch: Bool
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
    let resolved = Slot.resolve(agentMode: agentMode, onboardingMode: onboardingMode)
    Group {
      switch resolved {
      case .none:
        EmptyView()
      case .agent(let mode):
        CodingAgentsSidebarCardView(store: store, mode: mode)
          .transition(Slot.transition)
      case .nestedWorktreesOnboarding:
        NestedWorktreesOnboardingCardView()
          .transition(Slot.transition)
      }
    }
    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: resolved.transitionToken)
  }

  /// Resolution layer between live state and the rendered branch. Pure so tests
  /// can lock the priority rules and `transitionToken` stability without
  /// exercising the SwiftUI rendering path.
  enum Slot: Equatable {
    case none
    case agent(CodingAgentsSidebarCardView.Mode)
    case nestedWorktreesOnboarding

    static let transition: AnyTransition = .move(edge: .bottom).combined(with: .opacity)

    static func resolve(
      agentMode: CodingAgentsSidebarCardView.Mode,
      onboardingMode: NestedWorktreesOnboardingCardView.Mode
    ) -> Slot {
      switch agentMode {
      case .updatesAvailable, .promptInstall: return .agent(agentMode)
      case .hidden: break
      }
      return onboardingMode == .visible ? .nestedWorktreesOnboarding : .none
    }

    /// Hashable identity used by `.animation(_:value:)`. Same-variant state
    /// changes share a token so the entry transition only fires when the
    /// rendered branch actually changes. Keyed off case names rather than
    /// `SkillAgent.rawValue` so a future user-facing rename of an agent's
    /// raw value doesn't silently change transition stability.
    var transitionToken: String {
      switch self {
      case .none: "none"
      case .agent(.updatesAvailable(let agents)):
        "agent:updates:" + agents.map { String(describing: $0) }.sorted().joined(separator: ",")
      case .agent(.promptInstall): "agent:promptInstall"
      case .agent(.hidden):
        // `resolve` collapses `.hidden` to `.none` so this is unreachable in
        // production. Returning a stable string keeps the render path
        // crash-free if a future caller (e.g. a test or debug surface)
        // constructs `.agent(.hidden)` directly.
        "agent:hidden"
      case .nestedWorktreesOnboarding: "nestedWorktrees:visible"
      }
    }
  }
}
