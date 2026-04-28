import SwiftUI

struct TerminalTabCloseButtonBackground: View {
  let isPressing: Bool
  let isHoveringClose: Bool

  @Environment(\.surfaceChromeColorScheme)
  private var surfaceChromeColorScheme

  var body: some View {
    Circle()
      .fill(backgroundColor)
  }

  private var backgroundColor: Color {
    if isPressing {
      return chromeOverlayColor.opacity(0.16)
    }
    if isHoveringClose {
      return chromeOverlayColor.opacity(0.12)
    }
    return .clear
  }

  private var chromeOverlayColor: Color {
    surfaceChromeColorScheme == .dark ? .white : .black
  }
}
