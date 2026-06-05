import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

struct TerminalTabLabelView: View {
  let tab: TerminalTabItem
  let isActive: Bool
  let isHoveringTab: Bool
  let isHoveringClose: Bool
  /// Per-tab scoped store. The badge subview observes `state.agents` here
  /// instead of iterating worktree-wide presence, so an agent storm on tab B
  /// doesn't invalidate tab A's label body.
  let tabStore: StoreOf<TerminalTabFeature>

  var body: some View {
    HStack(spacing: TerminalTabBarMetrics.contentSpacing) {
      TerminalTabAgentBadge(tabStore: tabStore)
      if let icon = tab.icon {
        Image(systemName: icon)
          .imageScale(.small)
          .foregroundStyle(tab.tintColor?.color ?? TerminalTabBarColors.activeText)
          .frame(
            width: TerminalTabBarMetrics.closeButtonSize,
            height: TerminalTabBarMetrics.closeButtonSize
          )
          .accessibilityHidden(true)
      }
      TerminalTabTitleLabel(title: tab.displayTitle, isActive: isActive, isDirty: tab.isDirty)
        .equatable()
      Spacer(minLength: TerminalTabBarMetrics.contentTrailingSpacing)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .contentShape(.rect)
    .padding(.horizontal, TerminalTabBarMetrics.tabHorizontalPadding)
    .padding(.trailing, TerminalTabBarMetrics.trailingSlotWidth + TerminalTabBarMetrics.contentSpacing)
  }
}

/// Equatable barrier around the shimmering title: a busy trigger that doesn't
/// change the title / active / dirty inputs skips this leaf, so the shimmer
/// sweep keeps running uninterrupted instead of re-rendering per report.
private struct TerminalTabTitleLabel: View, Equatable {
  let title: String
  let isActive: Bool
  let isDirty: Bool

  var body: some View {
    Text(title)
      .font(.caption)
      .fontWeight(isActive ? .semibold : .regular)
      .lineLimit(1)
      .foregroundStyle(TerminalTabBarColors.activeText)
      .shimmer(isActive: isDirty)
  }
}

/// Reads agent presence off the per-tab scoped store, so an agent storm on
/// tab B invalidates only tab B's badge leaf. Mirrors sidebar's
/// `RunningAgentsBadgeContent` pattern with the inner Equatable wrapper.
private struct TerminalTabAgentBadge: View {
  let tabStore: StoreOf<TerminalTabFeature>

  var body: some View {
    let agents = tabStore.state.agents
    if !agents.isEmpty {
      TerminalTabAgentBadgeContent(agents: agents)
        .equatable()
    }
  }
}

private struct TerminalTabAgentBadgeContent: View, Equatable {
  let agents: [AgentPresenceFeature.AgentInstance]

  var body: some View {
    AgentAvatarGroupView(instances: agents, size: 14)
      .padding(.trailing, 2)
  }
}
