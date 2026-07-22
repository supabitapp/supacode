import SwiftUI

/// The circular control in a tab's trailing slot. Close and exit-split-zoom are the same
/// button with a different symbol and action, so they share every interaction rule.
struct TerminalTabTrailingButton: View {
  let title: String
  let systemImage: String
  /// Ghostty action name the tooltip reads the chord from.
  let ghosttyAction: String
  let isVisible: Bool
  let action: () -> Void
  @Binding var gestureActive: Bool

  @Environment(GhosttyShortcutManager.self)
  private var ghosttyShortcuts

  @State private var isPressing = false
  @State private var isHovering = false

  var body: some View {
    Button(title, systemImage: systemImage, action: action)
      .labelStyle(.iconOnly)
      .buttonStyle(TerminalPressTrackingButtonStyle(isPressed: $isPressing))
      .font(.caption2)
      .bold()
      .foregroundStyle(
        isHovering ? TerminalTabBarColors.activeText : TerminalTabBarColors.inactiveText
      )
      .frame(width: TerminalTabBarMetrics.closeButtonSize, height: TerminalTabBarMetrics.closeButtonSize)
      .background(TerminalTabTrailingButtonBackground(isPressing: isPressing, isHovering: isHovering))
      .clipShape(.circle)
      .contentShape(.rect)
      .onHover { hovering in
        isHovering = hovering
      }
      .onChange(of: isPressing) { _, pressed in
        gestureActive = pressed
      }
      // A press that ends after the slot or split zoom unmounts this never delivers its
      // own reset, which would suppress the row's drag gesture for good.
      .onDisappear {
        guard isPressing else { return }
        gestureActive = false
      }
      .help(helpText)
      .opacity(isVisible ? 1 : 0)
      .allowsHitTesting(isVisible)
      .animation(.easeInOut(duration: TerminalTabBarMetrics.hoverAnimationDuration), value: isVisible)
  }

  private var helpText: String {
    guard let shortcut = ghosttyShortcuts.display(for: ghosttyAction) else { return title }
    return "\(title) (\(shortcut))"
  }
}

private struct TerminalTabTrailingButtonBackground: View {
  let isPressing: Bool
  let isHovering: Bool

  var body: some View {
    Circle()
      .fill(backgroundStyle)
  }

  private var backgroundStyle: AnyShapeStyle {
    switch true {
    case isPressing: AnyShapeStyle(.tertiary)
    case isHovering: AnyShapeStyle(.quaternary)
    default: AnyShapeStyle(.clear)
    }
  }
}
