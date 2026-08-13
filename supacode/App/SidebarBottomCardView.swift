import ComposableArchitecture
import Sharing
import SupacodeSettingsFeature
import SupacodeSettingsShared
import SwiftUI

/// Mutually-exclusive host for the pinned sidebar bottom card. Priority order:
/// 1. Coding-agent updates available / initial install prompt
///    (`CodingAgentsSidebarCardView`).
/// 2. New layout announcement (`LayoutModesCardView`).
/// 3. File explorer Beta announcement (`FileExplorerBetaCardView`).
/// 4. Nothing.
///
/// Owns the `@Shared(.appStorage)` reads as stored properties so SwiftUI
/// observes them at this layer and re-renders when the user dismisses a
/// card. Each downstream card's `resolveMode(...)` takes the resolved values
/// as parameters so they stay pure (no hidden global reads inside a static).
struct SidebarBottomCardView: View {
  let store: StoreOf<AppFeature>
  @Shared(.appStorage("codingAgentsSetupCardDismissedAt"))
  private var agentDismissedAt: Date = .distantPast
  @Shared(.appStorage("fileExplorerBetaOnboardingDismissedAt"))
  private var fileExplorerBetaDismissedAt: Date = .distantPast
  @Shared(.appStorage("layoutModesOnboardingDismissedAt"))
  private var layoutModesDismissedAt: Date = .distantPast

  var body: some View {
    let agentMode = CodingAgentsSidebarCardView.resolveMode(
      for: store, dismissedAt: agentDismissedAt
    )
    let fileExplorerBetaMode = FileExplorerBetaCardView.resolveMode(
      dismissedAt: fileExplorerBetaDismissedAt
    )
    let layoutModesMode = LayoutModesCardView.resolveMode(
      dismissedAt: layoutModesDismissedAt
    )
    let resolved = Slot.resolve(
      gitEnvironmentError: store.repositories.gitEnvironmentError,
      cards: Slot.resolve(
        cards: Slot.CardModes(
          agent: agentMode,
          layoutModes: layoutModesMode,
          fileExplorerBeta: fileExplorerBetaMode
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
      case .layoutModes:
        LayoutModesCardView()
          .transition(Slot.transition)
      case .fileExplorerBeta:
        FileExplorerBetaCardView()
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
    case layoutModes
    case fileExplorerBeta

    static let transition: AnyTransition = .move(edge: .bottom).combined(with: .opacity)

    /// Per-card visibility modes feeding priority resolution, grouped so the
    /// resolver stays under the parameter-count limit as cards are added.
    struct CardModes: Equatable {
      var agent: CodingAgentsSidebarCardView.Mode
      var layoutModes: LayoutModesCardView.Mode
      var fileExplorerBeta: FileExplorerBetaCardView.Mode
    }

    /// Layer a blocked-git error over the resolved card: it makes the app
    /// largely unusable, so it pre-empts every onboarding / announcement card.
    static func resolve(gitEnvironmentError: GitEnvironmentError?, cards: Slot) -> Slot {
      if let gitEnvironmentError { return .gitEnvironmentError(gitEnvironmentError) }
      return cards
    }

    static func resolve(cards: CardModes) -> Slot {
      switch cards.agent {
      case .promptInstall: return .agent(cards.agent)
      case .hidden: break
      }
      // Newest card wins. `layoutModes` is the most recent and pre-empts the
      // older prompts; insert future cards at the top here.
      if cards.layoutModes == .visible { return .layoutModes }
      return cards.fileExplorerBeta == .visible ? .fileExplorerBeta : .none
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
      case .agent(.promptInstall): "agent:promptInstall"
      case .agent(.hidden): "agent:hidden"
      case .layoutModes: "layoutModes:visible"
      case .fileExplorerBeta: "fileExplorerBeta:visible"
      }
    }
  }
}
