import SwiftUI

struct TerminalTabBarBackground: View {
  @Environment(\.controlActiveState)
  private var activeState
  @Environment(\.surfaceTopChromeBackgroundOpacity)
  private var surfaceTopChromeBackgroundOpacity
  @Environment(\.surfaceChromeBackgroundColor)
  private var surfaceChromeBackgroundColor

  var body: some View {
    Rectangle()
      .fill(surfaceChromeBackgroundColor.opacity(chromeBackgroundOpacity))
  }

  private var chromeBackgroundOpacity: Double {
    let baseOpacity = surfaceTopChromeBackgroundOpacity
    if activeState == .inactive {
      return baseOpacity * 0.95
    }
    return baseOpacity
  }
}
