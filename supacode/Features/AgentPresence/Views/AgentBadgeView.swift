import SupacodeSettingsShared
import SwiftUI

/// Single circular badge showing an agent's mark on a filled background.
struct AgentBadgeView: View {
  let agent: SkillAgent
  let size: CGFloat
  @Environment(\.pixelLength) private var pixelLength

  init(agent: SkillAgent, size: CGFloat = 14) {
    self.agent = agent
    self.size = size
  }

  var body: some View {
    Image(agent.assetName)
      .resizable()
      .aspectRatio(contentMode: .fit)
      .padding(size * 0.18)
      .frame(width: size, height: size)
      .foregroundStyle(.primary)
      .background(
        .bar.shadow(.drop(color: Color.black.opacity(0.05), radius: 1, x: 0, y: 1)),
        in: .circle
      )
      .overlay(Circle().strokeBorder(Color(nsColor: .separatorColor), lineWidth: pixelLength))
      .accessibilityLabel(agent.displayName)
  }
}
