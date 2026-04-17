import SupacodeSettingsShared
import SwiftUI

struct TerminalTabBackground: View {
  var isActive: Bool
  var isPressing: Bool
  var isDragging: Bool
  var isHovering: Bool
  var tintColor: TerminalTabTintColor?

  var body: some View {
    ZStack(alignment: .top) {
      if isActive {
        TerminalTabBarColors.activeTabBackground
      } else if isHovering || isPressing || isDragging {
        TerminalTabBarColors.hoveredTabBackground
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
            .fill(TerminalTabBarColors.separator)
            .frame(height: 1)
        }
      }
    }
  }
}
