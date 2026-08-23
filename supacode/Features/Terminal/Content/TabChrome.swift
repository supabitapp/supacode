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
  /// The title the content last reported, nil until it reports one (and nil for
  /// content kinds that never report one). Agent TUIs rewrite it several times a
  /// second, so it lives here rather than as a layout reducer action, and only
  /// one tab's label re-renders on a report.
  var reportedTitle: String? { get }
}

/// Resolves what a tab shows, and what the layout should persist for it, from
/// the layout's own title and the content's live reported title.
@MainActor
enum TabTitle {
  /// The title the record persists: the content's live report when it has one,
  /// else the layout's own. A locked tab owns its title (a shell report never
  /// reaches it), and the user override is excluded (it persists in its field).
  static func stored(for tab: TabItem, chrome: (any TabChrome)?) -> String {
    guard !tab.isLocked, let reported = chrome?.reportedTitle, !reported.isEmpty else {
      return tab.title
    }
    return reported
  }

  /// What the tab displays: a user override wins over the reported title.
  static func resolved(for tab: TabItem, chrome: (any TabChrome)?) -> String {
    tab.customTitle ?? stored(for: tab, chrome: chrome)
  }

  static func resolved(for tab: TabItem, runtime: ContentRuntime) -> String {
    resolved(for: tab, chrome: runtime.content(for: tab.content.id)?.chrome)
  }
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
  var reportedTitle: String?

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
