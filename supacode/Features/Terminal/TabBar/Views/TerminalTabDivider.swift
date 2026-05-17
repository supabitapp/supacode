import SwiftUI

struct TerminalTabDivider: View {
  @Environment(\.pixelLength) private var pixelLength

  var body: some View {
    Rectangle()
      .fill(.separator)
      .frame(width: pixelLength)
      .frame(height: TerminalTabBarMetrics.tabHeight)
  }
}
