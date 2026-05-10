import SupacodeSettingsShared
import SwiftUI

/// Avatar-group rendering of running agents. Shows up to `maxVisible` circular
/// badges with a slight overlap; any remaining agents collapse into a plain
/// `+N` label trailing the group.
struct AgentAvatarGroupView: View {
  /// Producer-sorted; duplicates kept (e.g. two Claude surfaces in the same
  /// tab show two Claude badges).
  let agents: [SkillAgent]
  let size: CGFloat
  let maxVisible: Int

  init(agents: [SkillAgent], size: CGFloat = 14, maxVisible: Int = 3) {
    self.agents = agents
    self.size = size
    self.maxVisible = maxVisible
  }

  private var visible: [SkillAgent] { Array(agents.prefix(maxVisible)) }
  private var overflow: Int { max(0, agents.count - maxVisible) }

  var body: some View {
    if agents.isEmpty {
      EmptyView()
    } else {
      HStack(spacing: 4) {
        HStack(spacing: -size * 0.35) {
          ForEach(Array(visible.enumerated()), id: \.offset) { index, agent in
            AgentBadgeView(agent: agent, size: size)
              .zIndex(Double(maxVisible - index))
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
    let names = agents.map(\.displayName).joined(separator: ", ")
    return "Running: \(names)"
  }
}
