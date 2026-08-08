import SwiftUI

struct TerminalTabDivider: View {
  @Environment(\.pixelLength)
  private var pixelLength

  var body: some View {
    Rectangle()
      .fill(Color(nsColor: .separatorColor))
      .frame(width: pixelLength)
      .frame(height: TerminalTabBarMetrics.tabHeight)
  }
}
