import SupacodeSettingsShared
import SwiftUI

/// Avatar-group rendering of running agents. Shows up to `maxVisible` circular
/// badges with a slight overlap; any remaining agents collapse into a plain
/// `+N` label trailing the group. Pass `maxVisible: .max` to render every
/// agent without an overflow chip (used by the sidebar setup card, which has
/// the horizontal room for the full lineup). Each badge contrast-flips its
/// colorScheme when its `awaitingInput` flag is set; the producer
/// (`AgentPresenceManager`) sorts those to the front so they always appear
/// first in the row.
struct AgentAvatarGroupView: View {
  /// Producer-sorted (awaiting-input first); duplicates kept (e.g. two
  /// Claude surfaces in the same tab show two Claude badges).
  let instances: [AgentPresenceManager.AgentInstance]
  let size: CGFloat
  let maxVisible: Int

  init(
    instances: [AgentPresenceManager.AgentInstance],
    size: CGFloat = 14,
    maxVisible: Int = 3
  ) {
    self.instances = instances
    self.size = size
    self.maxVisible = maxVisible
  }

  /// Convenience for static lineups (e.g. the sidebar setup card showing
  /// every supported agent) where no presence/activity is involved.
  init(agents: [SkillAgent], size: CGFloat = 14, maxVisible: Int = 3) {
    self.init(
      instances: agents.map { .init(agent: $0, activity: .idle) },
      size: size,
      maxVisible: maxVisible
    )
  }

  private var visible: [AgentPresenceManager.AgentInstance] { Array(instances.prefix(maxVisible)) }
  private var overflow: Int { max(0, instances.count - maxVisible) }

  /// Per-(agent, occurrence) identity stays stable when the awaiting-first
  /// sort moves agents between slots; `zIndex` baked into the same pass.
  private var visibleSlots: [Slot] {
    var counts: [SkillAgent: Int] = [:]
    let total = visible.count
    return visible.enumerated().map { index, instance in
      let occurrence = counts[instance.agent, default: 0]
      counts[instance.agent] = occurrence + 1
      return Slot(
        agent: instance.agent,
        occurrence: occurrence,
        awaitingInput: instance.awaitingInput,
        // Leftmost on top — stable regardless of `maxVisible`.
        zIndex: Double(total - index)
      )
    }
  }

  private struct Slot: Identifiable {
    let agent: SkillAgent
    let occurrence: Int
    let awaitingInput: Bool
    let zIndex: Double
    var id: AnyHashable { [AnyHashable(agent), AnyHashable(occurrence)] }
  }

  var body: some View {
    if !instances.isEmpty {
      HStack(spacing: 4) {
        HStack(spacing: -size * 0.35) {
          ForEach(visibleSlots) { slot in
            AgentBadgeView(agent: slot.agent, size: size, awaitingInput: slot.awaitingInput)
              .zIndex(slot.zIndex)
          }
        }
        if overflow > 0 {
          Text("+\(overflow)")
            .font(.system(size: size * 0.7, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(accessibilityLabel)
    }
  }

  private var accessibilityLabel: String {
    let names = instances.map(\.agent.displayName).joined(separator: ", ")
    return "Running: \(names)"
  }
}
