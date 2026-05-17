import SupacodeSettingsShared
import SwiftUI

/// Background fill + inactive-tab bottom separator. The top stripe is rendered
/// as an overlay at `TerminalTabView` level so it can paint over the adjacent
/// `TerminalTabDivider`s — the corner-radius `clipShape` on the tab would
/// otherwise clip a negative-padded stripe.
struct TerminalTabBackground: View {
  var isActive: Bool
  var isHovering: Bool
  var isPressing: Bool
  var isDragging: Bool

  @Environment(\.surfaceChromeAppearance)
  private var chromeAppearance
  @Environment(\.pixelLength)
  private var pixelLength

  var body: some View {
    Color.clear
      .overlay(alignment: .bottom) {
        if !isActive {
          Rectangle()
            .fill(chromeAppearance.overlayTint.opacity(chromeAppearance.separatorOpacity))
            .frame(height: pixelLength)
        }
      }
  }
}
