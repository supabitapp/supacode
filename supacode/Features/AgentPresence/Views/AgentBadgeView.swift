import SupacodeSettingsShared
import SwiftUI

/// Circular badge with the agent's mark. When `awaitingInput` flips, the
/// subtree's colorScheme is inverted so `.bar`, `.primary`, and asset
/// variants flip together — a contrast cue that doesn't clash with agent
/// marks that are already orange (Claude).
struct AgentBadgeView: View {
  let agent: SkillAgent
  let size: CGFloat
  let awaitingInput: Bool
  @Environment(\.pixelLength) private var pixelLength
  @Environment(\.colorScheme) private var colorScheme

  init(agent: SkillAgent, size: CGFloat = 14, awaitingInput: Bool = false) {
    self.agent = agent
    self.size = size
    self.awaitingInput = awaitingInput
  }

  var body: some View {
    // Read `awaitingInput` at body top so SwiftUI's diffing picks up the flag the moment it flips.
    let resolvedScheme: ColorScheme =
      awaitingInput
      ? (colorScheme == .dark ? .light : .dark)
      : colorScheme
    Image(agent.assetName)
      .resizable()
      .aspectRatio(contentMode: .fit)
      .accessibilityLabel(agent.displayName)
      .padding(size * 0.18)
      .frame(width: size, height: size)
      .foregroundStyle(.primary)
      .background(.bar.shadow(Self.dropShadow), in: .circle)
      .overlay(Circle().strokeBorder(.separator, lineWidth: pixelLength))
      .environment(\.colorScheme, resolvedScheme)
      .animation(.smooth, value: awaitingInput)
  }

  private static let dropShadow: ShadowStyle = .drop(
    color: Color.black.opacity(0.05), radius: 1, x: 0, y: 1
  )
}
