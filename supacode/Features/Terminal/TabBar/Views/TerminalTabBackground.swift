import SupacodeSettingsShared
import SwiftUI

struct TerminalTabBackground: View {
  var isActive: Bool
  var isPressing: Bool
  var isDragging: Bool
  var isHovering: Bool
  var tintColor: TerminalTabTintColor?

  @Environment(\.surfaceChromeBackgroundColor)
  private var surfaceChromeBackgroundColor
  @Environment(\.surfaceChromeColorScheme)
  private var surfaceChromeColorScheme

  var body: some View {
    ZStack(alignment: .top) {
      if isActive {
        Rectangle()
          .fill(surfaceChromeBackgroundColor)
        Rectangle()
          .fill(chromeOverlayColor.opacity(0.14))
      } else if isHovering || isPressing || isDragging {
        Rectangle()
          .fill(chromeOverlayColor.opacity(0.08))
      } else {
        TerminalTabBarColors.inactiveTabBackground
      }

      Rectangle()
        .fill(tintColor?.color ?? .accentColor)
        .frame(height: TerminalTabBarMetrics.activeIndicatorHeight)
        .opacity(isActive || tintColor != nil ? 1 : 0)

      if !isActive {
        VStack(spacing: 0) {
          Spacer(minLength: 0)
          Rectangle()
            .fill(chromeOverlayColor.opacity(separatorOpacity))
            .frame(height: 1)
        }
      }
    }
  }

  private var chromeOverlayColor: Color {
    surfaceChromeColorScheme == .dark ? .white : .black
  }

  private var separatorOpacity: Double {
    surfaceChromeColorScheme == .dark ? 0.22 : 0.14
  }
}
