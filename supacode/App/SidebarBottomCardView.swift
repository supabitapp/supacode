import ComposableArchitecture
import Sharing
import SupacodeSettingsFeature
import SupacodeSettingsShared
import SwiftUI

/// Mutually-exclusive host for the pinned sidebar bottom card. Priority order:
/// 1. Coding-agent updates available / initial install prompt
///    (`CodingAgentsSidebarCardView`).
/// 2. Menu bar visibility announcement (`MenuBarOnboardingCardView`).
/// 3. Remote repositories Beta announcement (`RemoteRepositoriesBetaCardView`).
/// 4. Terminal persistence onboarding prompt (`TerminalPersistenceOnboardingCardView`).
/// 5. Highlight Relevant onboarding prompt (`HighlightRelevantOnboardingCardView`).
/// 6. Nested-worktrees onboarding prompt (`NestedWorktreesOnboardingCardView`).
/// 7. Nothing.
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
  @Shared(.appStorage("menuBarOnboardingDismissedAt"))
  private var menuBarOnboardingDismissedAt: Date = .distantPast

  var body: some View {
    let agentMode = CodingAgentsSidebarCardView.resolveMode(
      for: store, dismissedAt: agentDismissedAt
    )
    let menuBarOnboardingMode = MenuBarOnboardingCardView.resolveMode(
      showsMenuBarIcon: store.settings.appVisibility.showsMenuBarIcon,
      dismissedAt: menuBarOnboardingDismissedAt
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
      gitEnvironmentError: store.repositories.gitEnvironmentError,
      cards: Slot.resolve(
        cards: Slot.CardModes(
          agent: agentMode,
          menuBarOnboarding: menuBarOnboardingMode,
          remoteRepositoriesBeta: remoteRepositoriesBetaMode,
          terminalPersistence: terminalPersistenceMode,
          highlight: highlightMode,
          nestedOnboarding: onboardingMode
        )
      )
    )
    Group {
      switch resolved {
      case .none:
        EmptyView()
      case .gitEnvironmentError(let error):
        GitEnvironmentErrorCardView(error: error)
          .transition(Slot.transition)
      case .agent(let mode):
        CodingAgentsSidebarCardView(store: store, mode: mode)
          .transition(Slot.transition)
      case .menuBarOnboarding:
        MenuBarOnboardingCardView()
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
    case gitEnvironmentError(GitEnvironmentError)
    case agent(CodingAgentsSidebarCardView.Mode)
    case menuBarOnboarding
    case remoteRepositoriesBeta
    case terminalPersistenceOnboarding
    case highlightRelevantOnboarding
    case nestedWorktreesOnboarding

    static let transition: AnyTransition = .move(edge: .bottom).combined(with: .opacity)

    /// Per-card visibility modes feeding priority resolution, grouped so the
    /// resolver stays under the parameter-count limit as cards are added.
    struct CardModes: Equatable {
      var agent: CodingAgentsSidebarCardView.Mode
      var menuBarOnboarding: MenuBarOnboardingCardView.Mode
      var remoteRepositoriesBeta: RemoteRepositoriesBetaCardView.Mode
      var terminalPersistence: TerminalPersistenceOnboardingCardView.Mode
      var highlight: HighlightRelevantOnboardingCardView.Mode
      var nestedOnboarding: NestedWorktreesOnboardingCardView.Mode
    }

    /// Layer a blocked-git error over the resolved card: it makes the app
    /// largely unusable, so it pre-empts every onboarding / announcement card.
    static func resolve(gitEnvironmentError: GitEnvironmentError?, cards: Slot) -> Slot {
      if let gitEnvironmentError { return .gitEnvironmentError(gitEnvironmentError) }
      return cards
    }

    static func resolve(cards: CardModes) -> Slot {
      switch cards.agent {
      case .updatesAvailable, .promptInstall: return .agent(cards.agent)
      case .hidden: break
      }
      // Newest card wins. `menuBarOnboarding` is the most recent and pre-empts
      // the older prompts; insert future cards at the top here.
      if cards.menuBarOnboarding == .visible { return .menuBarOnboarding }
      if cards.remoteRepositoriesBeta == .visible { return .remoteRepositoriesBeta }
      if cards.terminalPersistence == .visible { return .terminalPersistenceOnboarding }
      if cards.highlight == .visible { return .highlightRelevantOnboarding }
      return cards.nestedOnboarding == .visible ? .nestedWorktreesOnboarding : .none
    }

    /// Hashable identity used by `.animation(_:value:)`. Same-variant state
    /// changes share a token so the entry transition only fires when the
    /// rendered branch actually changes. Keyed off case names rather than
    /// `SkillAgent.rawValue` so a future user-facing rename of an agent's
    /// raw value doesn't silently change transition stability.
    var transitionToken: String {
      switch self {
      case .none: "none"
      case .gitEnvironmentError(let error): "gitEnvironmentError:" + String(describing: error)
      case .agent(.updatesAvailable(let agents)):
        "agent:updates:" + agents.map { String(describing: $0) }.sorted().joined(separator: ",")
      case .agent(.promptInstall): "agent:promptInstall"
      case .agent(.hidden): "agent:hidden"
      case .menuBarOnboarding: "menuBarOnboarding:visible"
      case .remoteRepositoriesBeta: "remoteRepositoriesBeta:visible"
      case .terminalPersistenceOnboarding: "terminalPersistence:visible"
      case .highlightRelevantOnboarding: "highlightRelevant:visible"
      case .nestedWorktreesOnboarding: "nestedWorktrees:visible"
      }
    }
  }
}
