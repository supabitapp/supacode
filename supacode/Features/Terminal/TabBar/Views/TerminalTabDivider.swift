import SwiftUI

struct TerminalTabDivider: View {
  @Environment(\.surfaceChromeAppearance)
  private var chromeAppearance
  @Environment(\.pixelLength)
  private var pixelLength

  var body: some View {
    Rectangle()
      .fill(chromeAppearance.overlayTint.opacity(chromeAppearance.separatorOpacity))
      .frame(width: pixelLength)
      .frame(height: TerminalTabBarMetrics.tabHeight)
  }
}
