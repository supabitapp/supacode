import ComposableArchitecture
import Sharing
import SwiftUI

/// Mutually-exclusive host for the pinned sidebar bottom card. Priority order:
/// 1. Coding-agent updates available / initial install prompt
///    (`CodingAgentsSidebarCardView`).
/// 2. Remote repositories Beta announcement (`RemoteRepositoriesBetaCardView`).
/// 3. Terminal persistence onboarding prompt (`TerminalPersistenceOnboardingCardView`).
/// 4. Highlight Relevant onboarding prompt (`HighlightRelevantOnboardingCardView`).
/// 5. Nested-worktrees onboarding prompt (`NestedWorktreesOnboardingCardView`).
/// 6. Nothing.
///
/// Owns the `@Shared(.appStorage)` reads as stored properties so SwiftUI
/// observes them at this layer and re-renders when the user dismisses a
/// card. Each downstream card's `resolveMode(...)` takes the resolved values
/// as parameters so they stay pure (no hidden global reads inside a static).
///
/// Toggles (`nestWorktreesByBranch`, `highlightRelevant`) are observed here so
/// the resolver can react, but the permadismiss side-effects on toggle-off
/// live in `SidebarCommands` (where the menu toggles actually fire), so they
/// work regardless of whether the sidebar column is currently visible.
struct SidebarBottomCardView: View {
  let store: StoreOf<AppFeature>
  @Shared(.appStorage("codingAgentsSetupCardDismissedAt"))
  private var agentDismissedAt: Date = .distantPast
  @Shared(.sidebarNestWorktreesByBranch) private var nestWorktreesByBranch: Bool
  @Shared(.appStorage("nestedWorktreesOnboardingDismissedAt"))
  private var onboardingDismissedAt: Date = .distantPast
  @Shared(.sidebarGroupPinnedRows) private var groupPinnedRows: Bool
  @Shared(.sidebarGroupActiveRows) private var groupActiveRows: Bool
  @Shared(.appStorage("highlightRelevantOnboardingDismissedAt"))
  private var highlightDismissedAt: Date = .distantPast
  @Shared(.appStorage("terminalPersistenceOnboardingDismissedAt"))
  private var terminalPersistenceDismissedAt: Date = .distantPast
  @Shared(.appStorage("remoteRepositoriesBetaOnboardingDismissedAt"))
  private var remoteRepositoriesBetaDismissedAt: Date = .distantPast

  var body: some View {
    let agentMode = CodingAgentsSidebarCardView.resolveMode(
      for: store, dismissedAt: agentDismissedAt
    )
    let terminalPersistenceMode = TerminalPersistenceOnboardingCardView.resolveMode(
      dismissedAt: terminalPersistenceDismissedAt
    )
    let remoteRepositoriesBetaMode = RemoteRepositoriesBetaCardView.resolveMode(
      dismissedAt: remoteRepositoriesBetaDismissedAt
    )
    let highlightMode = HighlightRelevantOnboardingCardView.resolveMode(
      groupPinnedRows: groupPinnedRows,
      groupActiveRows: groupActiveRows,
      dismissedAt: highlightDismissedAt
    )
    let onboardingMode = NestedWorktreesOnboardingCardView.resolveMode(
      nestWorktreesByBranch: nestWorktreesByBranch,
      dismissedAt: onboardingDismissedAt
    )
    let resolved = Slot.resolve(
      agentMode: agentMode,
      remoteRepositoriesBetaMode: remoteRepositoriesBetaMode,
      terminalPersistenceMode: terminalPersistenceMode,
      highlightMode: highlightMode,
      onboardingMode: onboardingMode
    )
    Group {
      switch resolved {
      case .none:
        EmptyView()
      case .agent(let mode):
        CodingAgentsSidebarCardView(store: store, mode: mode)
          .transition(Slot.transition)
      case .remoteRepositoriesBeta:
        RemoteRepositoriesBetaCardView()
          .transition(Slot.transition)
      case .terminalPersistenceOnboarding:
        TerminalPersistenceOnboardingCardView()
          .transition(Slot.transition)
      case .highlightRelevantOnboarding:
        HighlightRelevantOnboardingCardView()
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
  ///
  /// Priority order (highest first): agent install / updates prompt, then the
  /// newest shipped onboarding card, then older onboarding cards in descending
  /// age. Newest wins so a freshly shipped feature has visibility priority over
  /// older cards that the same user may have already seen.
  enum Slot: Equatable {
    case none
    case agent(CodingAgentsSidebarCardView.Mode)
    case remoteRepositoriesBeta
    case terminalPersistenceOnboarding
    case highlightRelevantOnboarding
    case nestedWorktreesOnboarding

    static let transition: AnyTransition = .move(edge: .bottom).combined(with: .opacity)

    static func resolve(
      agentMode: CodingAgentsSidebarCardView.Mode,
      remoteRepositoriesBetaMode: RemoteRepositoriesBetaCardView.Mode,
      terminalPersistenceMode: TerminalPersistenceOnboardingCardView.Mode,
      highlightMode: HighlightRelevantOnboardingCardView.Mode,
      onboardingMode: NestedWorktreesOnboardingCardView.Mode
    ) -> Slot {
      switch agentMode {
      case .updatesAvailable, .promptInstall: return .agent(agentMode)
      case .hidden: break
      }
      // Newest card wins. `remoteRepositoriesBeta` is the most recent and
      // pre-empts the older prompts; insert future cards at the top here.
      if remoteRepositoriesBetaMode == .visible { return .remoteRepositoriesBeta }
      if terminalPersistenceMode == .visible { return .terminalPersistenceOnboarding }
      if highlightMode == .visible { return .highlightRelevantOnboarding }
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
      case .agent(.hidden): "agent:hidden"
      case .remoteRepositoriesBeta: "remoteRepositoriesBeta:visible"
      case .terminalPersistenceOnboarding: "terminalPersistence:visible"
      case .highlightRelevantOnboarding: "highlightRelevant:visible"
      case .nestedWorktreesOnboarding: "nestedWorktrees:visible"
      }
    }
  }
}
