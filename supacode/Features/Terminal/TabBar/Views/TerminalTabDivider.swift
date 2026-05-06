import SwiftUI

struct TerminalTabDivider: View {
  @Environment(\.surfaceChromeAppearance)
  private var chromeAppearance

  var body: some View {
    Rectangle()
      .frame(width: 1)
      .frame(height: TerminalTabBarMetrics.tabHeight)
      .foregroundStyle(chromeAppearance.overlayTint.opacity(chromeAppearance.separatorOpacity))
  }
}
