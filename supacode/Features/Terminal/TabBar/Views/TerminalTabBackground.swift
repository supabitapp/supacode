import SupacodeSettingsShared
import SwiftUI

struct TerminalTabBackground: View {
  var isActive: Bool
  var isHovering: Bool
  var isPressing: Bool
  var isDragging: Bool
  var tintColor: TerminalTabTintColor?

  @Environment(\.surfaceChromeAppearance)
  private var chromeAppearance

  var body: some View {
    Color.clear
      .overlay(alignment: .top) {
        Rectangle()
          .fill(tintColor?.color ?? .accentColor)
          .frame(height: TerminalTabBarMetrics.activeIndicatorHeight)
          .opacity(stripeOpacity)
      }
      .overlay(alignment: .bottom) {
        if !isActive {
          Rectangle()
            .fill(chromeAppearance.overlayTint.opacity(chromeAppearance.separatorOpacity))
            .frame(height: 1)
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
