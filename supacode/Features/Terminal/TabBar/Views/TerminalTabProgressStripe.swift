import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

/// Top-of-tab colored stripe carrying both the tint indicator and the OSC-9
/// progress signal. Rendered as an overlay above the tab's `clipShape` so it
/// can paint over the adjacent `TerminalTabDivider`s via `-pixelLength`
/// horizontal padding, making the active tab read continuous across boundaries.
struct TerminalTabProgressStripe: View {
  let isActive: Bool
  let isHovering: Bool
  let isPressing: Bool
  let isDragging: Bool
  let tintColor: RepositoryColor?
  let tabStore: StoreOf<TerminalTabFeature>

  @Environment(\.pixelLength) private var pixelLength

  var body: some View {
    let progressDisplay = tabStore.state.progressDisplay
    let color = strokeColor(progressDisplay: progressDisplay)
    StripeBody(
      color: color,
      progressDisplay: progressDisplay,
      opacity: stripeOpacity(progressDisplay: progressDisplay),
      pixelLength: pixelLength
    )
  }

  private func stripeOpacity(progressDisplay: TerminalTabProgressDisplay?) -> Double {
    let hasProgress = progressDisplay != nil
    // The untinted fallback carries its own dimming via `.secondary`, so the
    // active tab paints at full opacity regardless.
    if isActive {
      return 1
    }
    // Inactive untinted tabs with no progress signal stay hidden.
    guard tintColor != nil || hasProgress else { return 0 }
    if isPressing || isDragging { return 1 }
    return isHovering
      ? TerminalTabBarMetrics.inactiveContentOpacityHover
      : TerminalTabBarMetrics.inactiveContentOpacityIdle
  }

  /// Resolves the stripe's primary color. Progress states override the tab
  /// tint; the no-tint / no-progress fallback paints `.secondary` so the active
  /// tab's indicator stays visible without an accent-color flash.
  private func strokeColor(progressDisplay: TerminalTabProgressDisplay?) -> Color {
    switch progressDisplay?.style {
    case .error: return .red
    case .paused: return .orange
    case .indeterminate, .determinate:
      return tintColor?.color ?? .accentColor
    case .none:
      return tintColor?.color ?? .secondary
    }
  }
}

private struct StripeBody: View {
  let color: Color
  let progressDisplay: TerminalTabProgressDisplay?
  let opacity: Double
  let pixelLength: CGFloat

  var body: some View {
    ZStack(alignment: .leading) {
      StripeBase(progressDisplay: progressDisplay, color: color)
      if case .determinate(let percent) = progressDisplay?.style {
        // scaleEffect composites the fill (no relayout) and the determinate
        // percent is bucketed upstream, so frequent agent ticks stop thrashing
        // layout / animation on the focused tab. No implicit per-percent tween.
        Rectangle()
          .fill(color)
          .scaleEffect(x: CGFloat(max(0, min(percent, 100))) / 100, anchor: .leading)
      }
    }
    .frame(maxWidth: .infinity)
    .frame(height: TerminalTabBarMetrics.activeIndicatorHeight)
    .padding(.horizontal, -pixelLength)
    .opacity(opacity)
    .allowsHitTesting(false)
  }
}

/// Background of the stripe. ERROR / PAUSE / INDETERMINATE paint the color
/// directly; the determinate variant paints a faded base behind the percent
/// fill so the partial-fill bar reads against a backdrop.
private struct StripeBase: View {
  let progressDisplay: TerminalTabProgressDisplay?
  let color: Color

  var body: some View {
    Rectangle()
      .fill(isDeterminate ? color.opacity(0.3) : color)
  }

  private var isDeterminate: Bool {
    if case .determinate = progressDisplay?.style { return true }
    return false
  }
}
