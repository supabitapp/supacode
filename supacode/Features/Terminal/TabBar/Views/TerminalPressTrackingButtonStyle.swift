import SwiftUI

struct TerminalPressTrackingButtonStyle: ButtonStyle {
  @Binding private var isPressed: Bool

  init(isPressed: Binding<Bool>) {
    self._isPressed = isPressed
  }

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .contentShape(.rect)
      .onChange(of: configuration.isPressed) { _, pressed in
        isPressed = pressed
      }
  }
}
