import SwiftUI

struct TerminalTabDivider: View {
  @Environment(\.surfaceChromeColorScheme)
  private var surfaceChromeColorScheme

  var body: some View {
    Rectangle()
      .frame(width: 1)
      .frame(height: TerminalTabBarMetrics.tabHeight)
      .foregroundStyle(chromeOverlayColor.opacity(separatorOpacity))
  }

  private var chromeOverlayColor: Color {
    surfaceChromeColorScheme == .dark ? .white : .black
  }

  private var separatorOpacity: Double {
    surfaceChromeColorScheme == .dark ? 0.22 : 0.14
  }
}
