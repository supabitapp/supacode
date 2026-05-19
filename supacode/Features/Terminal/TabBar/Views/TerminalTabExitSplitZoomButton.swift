import SwiftUI

struct TerminalTabExitSplitZoomButton: View {
  var isDragging: Bool
  var isShowingShortcutHint: Bool
  var dismissAction: () -> Void
  @Binding var closeButtonGestureActive: Bool

  @Environment(GhosttyShortcutManager.self)
  private var ghosttyShortcuts

  @State private var isPressing = false
  @State private var isHovering = false

  var body: some View {
    // Always visible; yields the slot to ⌘-hint and to drag, matching the close button.
    let isVisible = !isDragging && !isShowingShortcutHint
    Button("Exit Split Zoom", systemImage: "arrow.up.right.and.arrow.down.left") {
      dismissAction()
    }
    .labelStyle(.iconOnly)
    .buttonStyle(TerminalPressTrackingButtonStyle(isPressed: $isPressing))
    .font(.caption2)
    .bold()
    .foregroundStyle(
      isHovering ? TerminalTabBarColors.activeText : TerminalTabBarColors.inactiveText
    )
    .frame(width: TerminalTabBarMetrics.closeButtonSize, height: TerminalTabBarMetrics.closeButtonSize)
    .background(
      TerminalTabCloseButtonBackground(isPressing: isPressing, isHoveringClose: isHovering)
    )
    .clipShape(.circle)
    .contentShape(.rect)
    .onHover { hovering in
      isHovering = hovering
    }
    .onChange(of: isPressing) { _, pressed in
      closeButtonGestureActive = pressed
    }
    .help(helpText("Exit Split Zoom", shortcut: ghosttyShortcuts.display(for: "toggle_split_zoom")))
    .opacity(isVisible ? 1 : 0)
    .allowsHitTesting(isVisible)
    .animation(.easeInOut(duration: TerminalTabBarMetrics.hoverAnimationDuration), value: isVisible)
  }

  private func helpText(_ title: String, shortcut: String?) -> String {
    guard let shortcut else { return title }
    return "\(title) (\(shortcut))"
  }
}
