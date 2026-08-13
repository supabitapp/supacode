import SwiftUI

/// Live, observable chrome a content contributes to its tab in the strip: an
/// accessory view next to the icon slot, activity for the shimmer, progress
/// for the stripe, and read-only input state. Owned by the content so
/// content-specific state never leaks into the layout reducer; the strip
/// reads it as an observable leaf, bounding invalidation to one tab.
@MainActor
protocol TabChrome: AnyObject {
  /// Accessory rendered before the title (agent badges for terminals).
  var accessory: AnyView? { get }
  /// Whether the tab's title should shimmer.
  var isWorking: Bool { get }
  /// Drives the top-of-tab progress stripe.
  var progress: TerminalTabProgressDisplay? { get }
  /// Whether the terminal refuses input (a completed blocking script's parked
  /// shell). The tab's own `isLocked` drives the visible lock marker.
  var isReadOnly: Bool { get }
}

/// Terminal chrome, written by the content host and the agent-presence
/// fan-out. Survives hibernation because the owning `TerminalContent` does.
@MainActor
@Observable
final class TerminalTabChrome: TabChrome {
  var agents: [AgentPresenceFeature.AgentInstance] = []
  var isWorking = false
  var progress: TerminalTabProgressDisplay?
  var isReadOnly = false

  var accessory: AnyView? {
    guard !agents.isEmpty else { return nil }
    return AnyView(TerminalAgentBadgeAccessory(agents: agents).equatable())
  }
}

/// Equatable barrier under the type-erased accessory: the tab body re-runs on
/// hover and interaction churn, and this keeps unchanged badges from
/// rebuilding the avatar group each time.
private struct TerminalAgentBadgeAccessory: View, Equatable {
  let agents: [AgentPresenceFeature.AgentInstance]

  var body: some View {
    AgentAvatarGroupView(instances: agents, size: 14)
      .padding(.trailing, 2)
  }
}
