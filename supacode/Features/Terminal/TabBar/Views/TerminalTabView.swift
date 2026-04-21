import AppKit
import SwiftUI

struct TerminalTabView: View {
  let tab: TerminalTabItem
  let isActive: Bool
  let isDragging: Bool
  let tabIndex: Int
  let fixedWidth: CGFloat?
  let hasNotification: Bool
  let onSelect: () -> Void
  let onClose: () -> Void
  @Binding var closeButtonGestureActive: Bool

  @State private var isHovering = false
  @State private var isHoveringClose = false
  @State private var isPressing = false
  @Environment(CommandKeyObserver.self) private var commandKeyObserver

  var body: some View {
    ZStack(alignment: .trailing) {
      Button(action: onSelect) {
        TerminalTabLabelView(
          tab: tab,
          isActive: isActive,
          isHoveringTab: isHovering,
          isHoveringClose: isHoveringClose,
          shortcutHint: shortcutHint,
          showsShortcutHint: showsShortcutHint
        )
      }
      .buttonStyle(TerminalTabButtonStyle(isPressing: $isPressing))
      .frame(
        minWidth: TerminalTabBarMetrics.tabMinWidth,
        maxWidth: TerminalTabBarMetrics.tabMaxWidth,
        minHeight: TerminalTabBarMetrics.tabHeight,
        maxHeight: TerminalTabBarMetrics.tabHeight
      )
      .frame(width: fixedWidth)
      .contentShape(.rect)
      .help("Open tab \(tab.title)")
      .accessibilityLabel(tab.title)

      // The dot and close X share the same trailing slot: the dot is
      // visible when the tab is idle and has unread notifications, the
      // close button replaces it on hover. `TerminalTabCloseButton` already
      // owns the hover visibility — we mirror it inverted here.
      ZStack {
        TabNotificationDot()
          .opacity(isShowingNotificationDot ? 1 : 0)
          .allowsHitTesting(false)
        TerminalTabCloseButton(
          isHoveringTab: isHovering,
          isDragging: isDragging,
          isShowingShortcutHint: showsShortcutHint,
          closeAction: onClose,
          closeButtonGestureActive: $closeButtonGestureActive,
          isHoveringClose: $isHoveringClose
        )
      }
      .animation(.easeInOut(duration: TerminalTabBarMetrics.hoverAnimationDuration), value: isHovering)
      .animation(.easeInOut(duration: 0.2), value: hasNotification)
      .padding(.trailing, TerminalTabBarMetrics.tabHorizontalPadding)
    }
    .background {
      TerminalTabBackground(
        isActive: isActive,
        isPressing: isPressing,
        isDragging: isDragging,
        isHovering: isHovering,
        tintColor: tab.tintColor
      )
      .animation(.easeInOut(duration: TerminalTabBarMetrics.hoverAnimationDuration), value: isHovering)
    }
    .padding(.bottom, isActive ? TerminalTabBarMetrics.activeTabBottomPadding : 0)
    .offset(y: isActive ? TerminalTabBarMetrics.activeTabOffset : 0)
    .clipShape(.rect(cornerRadius: TerminalTabBarMetrics.tabCornerRadius))
    .contentShape(.rect)
    .onHover { hovering in
      isHovering = hovering
    }
    .zIndex(isActive ? 2 : (isDragging ? 3 : 0))
    .overlay {
      MiddleClickView(action: onClose)
    }
  }

  private var shortcutHint: String? {
    let number = tabIndex + 1
    guard number > 0 && number <= 9 else { return nil }
    return "⌘\(number)"
  }

  private var showsShortcutHint: Bool {
    commandKeyObserver.isPressed && shortcutHint != nil
  }

  private var isShowingNotificationDot: Bool {
    hasNotification && !isHovering && !isHoveringClose && !isDragging && !showsShortcutHint
  }
}

private struct TabNotificationDot: View {
  var body: some View {
    Circle()
      .fill(.orange)
      .frame(width: 6, height: 6)
      .frame(width: TerminalTabBarMetrics.closeButtonSize, height: TerminalTabBarMetrics.closeButtonSize)
      .accessibilityLabel("Unread notifications")
  }
}

private struct MiddleClickView: NSViewRepresentable {
  let action: () -> Void

  func makeNSView(context: Context) -> MiddleClickNSView {
    MiddleClickNSView(action: action)
  }

  func updateNSView(_ nsView: MiddleClickNSView, context: Context) {
    nsView.action = action
  }
}

private final class MiddleClickNSView: NSView {
  var action: () -> Void

  init(action: @escaping () -> Void) {
    self.action = action
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard let event = NSApp.currentEvent,
      event.type == .otherMouseDown || event.type == .otherMouseUp
    else { return nil }
    return super.hitTest(point)
  }

  override func otherMouseUp(with event: NSEvent) {
    if event.buttonNumber == 2 {
      action()
    } else {
      super.otherMouseUp(with: event)
    }
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
