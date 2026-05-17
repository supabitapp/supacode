import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

struct TerminalTabBackground: View {
  var isActive: Bool
  var isHovering: Bool
  var isPressing: Bool
  var isDragging: Bool
  var tintColor: RepositoryColor?
  /// Per-tab store. The top stripe reads `state.progressDisplay` to recolor
  /// itself (red on ERROR, orange on PAUSE, accent/tint on busy, percent fill
  /// on determinate) — the per-surface progress overlay was deleted and the
  /// stripe now carries the OSC-9 signal alongside its existing tint role.
  var tabStore: StoreOf<TerminalTabFeature>?

  @Environment(\.surfaceChromeAppearance)
  private var chromeAppearance
  @Environment(\.pixelLength)
  private var pixelLength

  var body: some View {
    Color.clear
      .overlay(alignment: .top) {
        ProgressStripe(
          tintColor: tintColor,
          opacity: stripeOpacity,
          progressDisplay: tabStore?.state.progressDisplay,
          pixelLength: pixelLength
        )
      }
      .overlay(alignment: .bottom) {
        if !isActive {
          Rectangle()
            .fill(.separator)
            .frame(height: pixelLength)
        }
      }
  }

  private var stripeOpacity: Double {
    guard !isActive else { return 1 }
    guard tintColor != nil else { return 0 }
    // Mirror `TerminalTabView.contentOpacity` so a press/drag on a tinted
    // inactive tab snaps the stripe to full at the same time as the content.
    if isPressing || isDragging { return 1 }
    return isHovering
      ? TerminalTabBarMetrics.inactiveContentOpacityHover
      : TerminalTabBarMetrics.inactiveContentOpacityIdle
  }
}

/// Renders the top stripe. When `progressDisplay` is nil the stripe paints
/// `tintColor ?? .accentColor`. When present, the progress payload overrides:
/// error → red, paused → orange, indeterminate → tint/accent, determinate →
/// partial fill width × percent / 100.
private struct ProgressStripe: View {
  let tintColor: RepositoryColor?
  let opacity: Double
  let progressDisplay: TerminalTabProgressDisplay?
  let pixelLength: CGFloat

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        ProgressStripeBase(progressDisplay: progressDisplay, color: strokeColor)
        if case .determinate(let percent) = progressDisplay?.style {
          Rectangle()
            .fill(strokeColor)
            .frame(width: proxy.size.width * CGFloat(max(0, min(percent, 100))) / 100)
            .animation(.easeInOut(duration: 0.2), value: percent)
        }
      }
    }
    // Stripe paints over the 1-pixel separator on both ends so the active tab
    // reads continuous across boundaries instead of broken at each notch.
    .padding(.horizontal, -pixelLength)
    .frame(height: TerminalTabBarMetrics.activeIndicatorHeight)
    .opacity(opacity)
  }

  /// Resolves the stripe's primary color. Progress states override the tab tint.
  private var strokeColor: Color {
    switch progressDisplay?.style {
    case .error: return .red
    case .paused: return .orange
    case .indeterminate, .determinate, nil:
      return tintColor?.color ?? .accentColor
    }
  }
}

/// Background of the stripe. When carrying ERROR / PAUSE / INDETERMINATE
/// state the stripe paints the state color directly; the determinate variant
/// paints a faded base behind the percent fill for the bar metaphor.
private struct ProgressStripeBase: View {
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
