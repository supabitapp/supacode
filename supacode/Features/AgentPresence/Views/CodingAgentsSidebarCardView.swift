import ComposableArchitecture
import Sharing
import SupacodeSettingsFeature
import SupacodeSettingsShared
import SwiftUI

/// Pinned bottom-of-sidebar card. Three states (mutually exclusive):
/// - Any agent integration `.outdated` → "Updates available" with avatars
///   of just the outdated agents and a Review-in-Settings link.
/// - Otherwise, if no agent is installed and the user has never dismissed
///   the prompt → "More functionality" with avatars of every supported
///   agent, the same Review link, plus a dismiss button.
/// - Otherwise → nothing (returns `nil`-shaped empty container).
struct CodingAgentsSidebarCardView: View {
  let store: StoreOf<AppFeature>
  @Environment(\.openWindow) private var openWindow
  // `.distantPast` sentinel for "never dismissed". Stamps older than
  // `cardRelevantSinceDate` are stale and re-engage the user.
  @Shared(.appStorage("codingAgentsSetupCardDismissedAt")) private var dismissedAt: Date = .distantPast

  /// Bump to release-day each time the prompt's content materially changes —
  /// users who dismissed before this date see the prompt again.
  static let cardRelevantSinceDate = Date(timeIntervalSince1970: 1_778_371_200)  // 2026-05-10.

  /// Stamps before `relevantSince` are treated as stale, so re-engagement is
  /// just `cardRelevantSinceDate += material change`.
  static func isDismissed(at dismissedAt: Date, relevantSince: Date = Self.cardRelevantSinceDate) -> Bool {
    dismissedAt >= relevantSince
  }

  var body: some View {
    let states = store.settings.agentIntegrationStates
    let mode = Self.mode(for: states, dismissed: Self.isDismissed(at: dismissedAt))
    switch mode {
    case .updatesAvailable(let agents):
      card(
        agents: agents,
        title: "Update agent integration",
        body: "Re-install to pick up the latest hooks for these agents.",
        showsDismiss: false
      )
    case .promptInstall:
      card(
        agents: SkillAgent.allCases,
        title: "Advanced agent integration",
        body: "Install hooks and skills to enable rich notifications and presence badges.",
        showsDismiss: true
      )
    case .hidden:
      EmptyView()
    }
  }

  // MARK: - Card.

  @ViewBuilder
  private func card(
    agents: [SkillAgent], title: LocalizedStringKey, body: LocalizedStringKey, showsDismiss: Bool
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .center, spacing: 0) {
        AgentAvatarGroupView(agents: agents, size: 22, maxVisible: .max)
        Spacer(minLength: 8)
        if showsDismiss {
          Button {
            $dismissedAt.withLock { $0 = .now }
          } label: {
            Image(systemName: "xmark")
              .font(.caption2)
              .foregroundStyle(.secondary)
              .frame(width: 18, height: 18)
              .contentShape(.rect)
          }
          .buttonStyle(.plain)
          .help("Dismiss")
          .accessibilityLabel("Dismiss")
        }
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.subheadline)
          .fontWeight(.semibold)
        Text(body)
          .font(.caption)
          .foregroundStyle(.secondary)
        Button("Review in Settings") {
          // Both calls are needed: `setSelection` routes the Settings
          // view, `openWindow` brings it forward when it's already open
          // on Developer (selection no-op wouldn't trigger the bridge).
          store.send(.settings(.setSelection(.developer)))
          openWindow(id: WindowID.settings)
        }
        .buttonStyle(.link)
        .font(.caption)
        .padding(.top, 2)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .glassEffect(.regular, in: .rect(cornerRadius: 10))
    .padding(.horizontal, 10)
    .padding(.bottom, 10)
  }

  // MARK: - Mode resolution.

  enum Mode: Equatable {
    /// No card to show. Named `.hidden` (not `.none`) so an `Optional<Mode>`
    /// caller can't silently match the wrong branch.
    case hidden
    case updatesAvailable([SkillAgent])
    case promptInstall
  }

  /// Pure resolver: chooses which card (if any) to show given the current
  /// integration states and dismissal flag. Tested separately so the view
  /// stays a thin renderer. Always waits for every agent to resolve before
  /// committing to a card — avoids the avatar group regrowing mid-launch
  /// as per-agent probes return staggered.
  static func mode(
    for states: [SkillAgent: AgentIntegrationRowState], dismissed: Bool
  ) -> Mode {
    let stillChecking = SkillAgent.allCases.contains { states[$0]?.isResolved != true }
    if stillChecking { return .hidden }
    let outdated = SkillAgent.allCases.filter {
      states[$0]?.integrationState == .outdated
    }
    if !outdated.isEmpty { return .updatesAvailable(outdated) }
    let anyInstalled = SkillAgent.allCases.contains {
      states[$0]?.integrationState == .installed
    }
    if anyInstalled || dismissed { return .hidden }
    return .promptInstall
  }
}

extension AgentIntegrationRowState {
  fileprivate var integrationState: AgentIntegrationState? {
    if case .ready(let state) = self { return state }
    return nil
  }

  fileprivate var isResolved: Bool {
    switch self {
    case .ready, .failed: true
    case .checking, .installing, .uninstalling: false
    }
  }
}
