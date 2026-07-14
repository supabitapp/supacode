import SupacodeSettingsShared
import SwiftUI

/// The visual variant an agent badge renders for a given presence activity.
enum AgentBadgeVisual: Equatable {
  /// The plain agent mark on the standard badge.
  case normal
  /// Contrast-flipped badge: the agent is parked on the user.
  case awaitingInput
  /// Red badge the mark is knocked out of: the turn died on an error.
  case error
  /// Normal badge, pulsing: context compaction in progress.
  case compacting

  static func resolve(_ activity: AgentPresenceFeature.Activity) -> AgentBadgeVisual {
    switch activity {
    case .error: .error
    case .compacting: .compacting
    case .awaitingInput: .awaitingInput
    case .busy, .idle: .normal
    }
  }

  /// Tooltip and VoiceOver text. The avatar group ignores its children for
  /// accessibility, so it folds this into its own aggregate label.
  func describing(_ agent: SkillAgent) -> String {
    switch self {
    case .error: "\(agent.displayName) stopped on an error"
    case .compacting: "\(agent.displayName) is compacting context"
    case .awaitingInput, .normal: agent.displayName
    }
  }
}

/// Circular badge with the agent's mark, styled by its presence `activity` (see
/// `AgentBadgeVisual`). `awaitingInput` inverts the subtree's colorScheme rather
/// than tinting, so it doesn't clash with marks that are already orange.
struct AgentBadgeView: View {
  let agent: SkillAgent
  let size: CGFloat
  let activity: AgentPresenceFeature.Activity
  @Environment(\.pixelLength) private var pixelLength
  @Environment(\.colorScheme) private var colorScheme

  init(agent: SkillAgent, size: CGFloat = 14, activity: AgentPresenceFeature.Activity = .idle) {
    self.agent = agent
    self.size = size
    self.activity = activity
  }

  var body: some View {
    let visual = AgentBadgeVisual.resolve(activity)
    let resolvedScheme: ColorScheme =
      visual == .awaitingInput
      ? (colorScheme == .dark ? .light : .dark)
      : colorScheme
    // The errored mark is knocked out of the red circle in the scheme's own
    // background color rather than painted on top of it.
    let markColor: Color =
      visual == .error
      ? (resolvedScheme == .dark ? .black : .white)
      : (resolvedScheme == .dark ? .white : .black)

    Image(agent.assetName)
      // Force template on the red badge so a full-color mark still knocks out;
      // `nil` elsewhere keeps each asset's own catalog intent.
      .renderingMode(visual == .error ? .template : nil)
      .resizable()
      .aspectRatio(contentMode: .fit)
      .accessibilityLabel(visual.describing(agent))
      .padding(size * 0.18)
      .frame(width: size, height: size)
      .foregroundStyle(markColor)
      .background(Self.badgeFill(visual).shadow(Self.dropShadow), in: .circle)
      .overlay(Circle().strokeBorder(.separator, lineWidth: pixelLength))
      .environment(\.colorScheme, resolvedScheme)
      .help(visual.describing(agent))
      .animation(.smooth, value: activity)
      .modifier(CompactingPulse(isActive: visual == .compacting))
  }

  private static func badgeFill(_ visual: AgentBadgeVisual) -> AnyShapeStyle {
    visual == .error ? AnyShapeStyle(.red) : AnyShapeStyle(.bar)
  }

  private static let dropShadow: ShadowStyle = .drop(
    color: Color.black.opacity(0.05), radius: 1, x: 0, y: 1
  )
}

/// Pulses the badge while the agent compacts context: it contracts, shivers, and
/// settles back, then rests before the next pulse. Deliberately quieter than a
/// continuous spinner, since compaction resolves on its own. Held still under
/// `accessibilityReduceMotion`.
private struct CompactingPulse: ViewModifier {
  let isActive: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private enum Phase: CaseIterable {
    case rest
    case contract
    case shiverLeft
    case shiverRight
    case release

    var scale: CGFloat {
      switch self {
      case .rest, .release: 1
      case .contract, .shiverLeft, .shiverRight: 0.78
      }
    }

    var angle: Angle {
      switch self {
      case .shiverLeft: .degrees(-10)
      case .shiverRight: .degrees(10)
      case .rest, .contract, .release: .zero
      }
    }

    /// The animation that runs INTO this phase. `rest` changes nothing, so its
    /// duration is the gap between pulses.
    var animation: Animation {
      switch self {
      case .rest: .linear(duration: 2.4)
      case .contract: .spring(duration: 0.7)
      case .shiverLeft, .shiverRight: .easeInOut(duration: 0.3)
      case .release: .spring(duration: 0.9)
      }
    }
  }

  func body(content: Content) -> some View {
    if isActive, !reduceMotion {
      PhaseAnimator(Phase.allCases) { phase in
        content
          .scaleEffect(phase.scale)
          .rotationEffect(phase.angle)
      } animation: { phase in
        phase.animation
      }
    } else {
      content
    }
  }
}
