import ComposableArchitecture
import Sharing
import SupacodeSettingsFeature
import SupacodeSettingsShared
import SwiftUI

/// Pinned bottom-of-sidebar card. Shows the install prompt (avatars of every
/// supported agent, a Review-in-Settings link, and a dismiss button) when no
/// agent is installed and the user hasn't dismissed it; otherwise nothing.
///
/// Rendering goes through `SidebarCard` so the visual chrome stays in sync
/// with every other pinned sidebar card.
struct CodingAgentsSidebarCardView: View {
  let store: StoreOf<AppFeature>
  let mode: Mode

  /// Bump to release-day each time the prompt's content materially changes;
  /// users who dismissed before this date see the prompt again.
  static let cardRelevantSinceDate = Date(timeIntervalSince1970: 1_784_937_600)  // 2026-07-25.

  static func isDismissed(at dismissedAt: Date, relevantSince: Date = Self.cardRelevantSinceDate) -> Bool {
    SidebarCardRelevance.isDismissed(at: dismissedAt, relevantSince: relevantSince)
  }

  /// Resolve the active mode from the current store + the dismissal stamp.
  /// The caller owns the `@Shared` read so SwiftUI re-renders the priority
  /// host when the dismissal date changes; passing it in keeps this resolver
  /// pure and free of hidden global reads.
  static func resolveMode(for store: StoreOf<AppFeature>, dismissedAt: Date) -> Mode {
    Self.mode(
      for: store.settings.agentIntegrationStates,
      dismissed: Self.isDismissed(at: dismissedAt)
    )
  }

  var body: some View {
    switch mode {
    case .promptInstall:
      CodingAgentsCardBody(
        store: store,
        agents: SkillAgent.allCases,
        title: "Advanced agent integration",
        description: "Install hooks and skills to enable rich notifications and presence badges.",
        showsDismiss: true
      )
    case .hidden:
      EmptyView()
    }
  }

  // MARK: - Mode resolution.

  enum Mode: Equatable {
    /// No card to show. Named `.hidden` (not `.none`) so an `Optional<Mode>`
    /// caller can't silently match the wrong branch.
    case hidden
    case promptInstall
  }

  /// Pure resolver: chooses whether to show the install prompt given the
  /// current integration states and dismissal flag. Tested separately so the
  /// view stays a thin renderer. Always waits for every agent to resolve
  /// before committing to a card (avoids the avatar group regrowing mid-launch
  /// as per-agent probes return staggered).
  static func mode(
    for states: [SkillAgent: AgentIntegrationRowState],
    dismissed: Bool
  ) -> Mode {
    let stillChecking = SkillAgent.allCases.contains { states[$0]?.isResolved != true }
    if stillChecking { return .hidden }
    // Never upsell an install we can't rule out: an unreadable probe would
    // otherwise read as "nobody has it installed".
    let anyUndetermined = SkillAgent.allCases.contains { states[$0]?.isUndetermined == true }
    if anyUndetermined { return .hidden }
    let anyInstalled = SkillAgent.allCases.contains {
      states[$0]?.integrationState == .installed
    }
    if anyInstalled || dismissed { return .hidden }
    return .promptInstall
  }
}

private struct CodingAgentsCardBody: View {
  let store: StoreOf<AppFeature>
  let agents: [SkillAgent]
  let title: LocalizedStringKey
  let description: LocalizedStringKey
  let showsDismiss: Bool
  @Environment(\.openWindow) private var openWindow
  @Shared(.appStorage("codingAgentsSetupCardDismissedAt")) private var dismissedAt: Date = .distantPast

  var body: some View {
    SidebarCard(onDismiss: showsDismiss ? { $dismissedAt.withLock { $0 = .now } } : nil) {
      VStack(alignment: .leading, spacing: 2) {
        SidebarCardLabel(title: title, description: description)
        Button("Review in Settings") {
          // Both calls are needed: `setSelection` routes the Settings
          // view, `openWindow` brings it forward when it's already open
          // on Developer (selection no-op wouldn't trigger the bridge).
          store.send(.settings(.setSelection(.developer)))
          openWindow(id: WindowID.settings)
        }
        .buttonStyle(.link)
        .appFont(.caption)
        .padding(.top, 2)
      }
    } header: {
      AgentAvatarGroupView(agents: agents, size: 22, maxVisible: .max)
    }
  }
}

extension AgentIntegrationRowState {
  fileprivate var integrationState: AgentIntegrationState? {
    if case .ready(let state) = self { return state }
    return nil
  }

  fileprivate var isResolved: Bool {
    switch self {
    case .ready, .failed, .failedTransient, .undetermined: true
    case .checking, .installing, .uninstalling: false
    }
  }
}
