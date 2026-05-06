import SwiftUI

struct TerminalTabCloseButtonBackground: View {
  let isPressing: Bool
  let isHoveringClose: Bool

  @Environment(\.surfaceChromeAppearance)
  private var chromeAppearance

  var body: some View {
    Circle()
      .fill(backgroundColor)
  }

  private var backgroundColor: Color {
    if isPressing {
      return chromeAppearance.overlayTint.opacity(0.16)
    }
    if isHoveringClose {
      return chromeAppearance.overlayTint.opacity(0.12)
    }
    return .clear
  }
}
