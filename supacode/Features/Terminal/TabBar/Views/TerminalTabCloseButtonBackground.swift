import SwiftUI

struct TerminalTabCloseButtonBackground: View {
  let isPressing: Bool
  let isHoveringClose: Bool

  var body: some View {
    Circle()
      .fill(backgroundStyle)
  }

  private var backgroundStyle: AnyShapeStyle {
    switch true {
    case isPressing: AnyShapeStyle(.tertiary)
    case isHoveringClose: AnyShapeStyle(.quaternary)
    default: AnyShapeStyle(.clear)
    }
  }
}
