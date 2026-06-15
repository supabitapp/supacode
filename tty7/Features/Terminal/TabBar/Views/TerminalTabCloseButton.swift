import SwiftUI

struct TerminalTabCloseButton: View {
  var isHoveringTab: Bool
  var isDragging: Bool
  var isShowingShortcutHint: Bool
  var closeAction: () -> Void
  @Binding var closeButtonGestureActive: Bool
  @Binding var isHoveringClose: Bool

  @Environment(GhosttyShortcutManager.self)
  private var ghosttyShortcuts

  @State private var isPressing = false

  var body: some View {
    let showClose = (isHoveringTab || isHoveringClose) && !isDragging && !isShowingShortcutHint
    Button("Close Tab", systemImage: "xmark") {
      closeAction()
    }
    .labelStyle(.iconOnly)
    .buttonStyle(TerminalPressTrackingButtonStyle(isPressed: $isPressing))
    .font(.caption2)
    .bold()
    .foregroundStyle(
      isHoveringClose ? TerminalTabBarColors.activeText : TerminalTabBarColors.inactiveText
    )
    .frame(width: TerminalTabBarMetrics.closeButtonSize, height: TerminalTabBarMetrics.closeButtonSize)
    .background(
      TerminalTabCloseButtonBackground(isPressing: isPressing, isHoveringClose: isHoveringClose)
    )
    .clipShape(.circle)
    .contentShape(.rect)
    .onHover { hovering in
      isHoveringClose = hovering
    }
    .onChange(of: isPressing) { _, pressed in
      closeButtonGestureActive = pressed
    }
    .help(helpText("Close Tab", shortcut: ghosttyShortcuts.display(for: "close_tab")))
    .opacity(showClose ? 1 : 0)
    .allowsHitTesting(showClose)
    .animation(.easeInOut(duration: TerminalTabBarMetrics.hoverAnimationDuration), value: isHoveringTab)
  }

  private func helpText(_ title: String, shortcut: String?) -> String {
    guard let shortcut else { return title }
    return "\(title) (\(shortcut))"
  }
}
