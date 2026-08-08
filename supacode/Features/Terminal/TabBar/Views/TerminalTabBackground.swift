import SupacodeSettingsShared
import SwiftUI

/// Background fill + inactive-tab bottom separator. The top stripe is moved
/// to a `TerminalTabView` overlay so it can paint over adjacent dividers
/// without being clipped by the tab's `clipShape`.
struct TerminalTabBackground: View {
  var isActive: Bool
  var isHovering: Bool
  var isPressing: Bool
  var isDragging: Bool

  @Environment(\.pixelLength)
  private var pixelLength

  var body: some View {
    Color.clear
      .overlay(alignment: .bottom) {
        if !isActive {
          Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: pixelLength)
        }
      }
  }
}
