import AppKit
import SupacodeSettingsShared
import SwiftUI

struct TerminalTabView: View {
  let tab: TerminalTabItem
  let isActive: Bool
  let isDragging: Bool
  let tabIndex: Int
  let fixedWidth: CGFloat?
  let hasNotification: Bool
  let runningAgents: [AgentPresenceManager.AgentInstance]
  let onSelect: () -> Void
  let onClose: () -> Void
  let onRename: (String) -> Void
  @Binding var closeButtonGestureActive: Bool
  let isEditing: Bool
  let onBeginRename: () -> Void
  let onEndRename: () -> Void

  @State private var isHovering = false
  @State private var isHoveringClose = false
  @State private var isPressing = false
  @State private var editingTitle = ""
  @State private var initialEditingTitle = ""
  @State private var cancelOnExit = false
  @FocusState private var isFieldFocused: Bool
  @Environment(CommandKeyObserver.self) private var commandKeyObserver
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack(alignment: .trailing) {
      Button(action: onSelect) {
        TerminalTabLabelView(
          tab: tab,
          isActive: isActive,
          isHoveringTab: isHovering,
          isHoveringClose: isHoveringClose,
          shortcutHint: shortcutHint,
          showsShortcutHint: showsShortcutHint,
          runningAgents: runningAgents
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
      .help("Open tab \(tab.displayTitle)")
      .accessibilityLabel(tab.displayTitle)
      .allowsHitTesting(!isEditing)
      .opacity(isEditing ? 0 : 1)

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
      .opacity(isEditing ? 0 : 1)
      .allowsHitTesting(!isEditing)
    }
    .overlay {
      if isEditing {
        TextField("", text: $editingTitle)
          .textFieldStyle(.plain)
          .font(.caption)
          .focused($isFieldFocused)
          .foregroundStyle(TerminalTabBarColors.activeText)
          .accessibilityLabel("Rename tab")
          .padding(.horizontal, TerminalTabBarMetrics.tabHorizontalPadding)
          .padding(
            .trailing,
            TerminalTabBarMetrics.closeButtonSize + TerminalTabBarMetrics.contentSpacing
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
          .onSubmit { onEndRename() }
          .onExitCommand {
            cancelOnExit = true
            onEndRename()
          }
          .onChange(of: isFieldFocused) { _, focused in
            guard !focused, isEditing else { return }
            onEndRename()
          }
      }
    }
    .opacity(contentOpacity)
    .saturation(contentSaturation)
    .background {
      TerminalTabBackground(
        isActive: isActive,
        isHovering: isHovering,
        isPressing: isPressing,
        isDragging: isDragging,
        tintColor: tab.tintColor
      )
    }
    // Below `.background` so the stripe's opacity animates in lockstep with
    // the foreground content; the previous `.background { ... }.animation`
    // pairing was lost during a refactor and the stripe started snapping.
    .animation(
      reduceMotion ? nil : .easeInOut(duration: TerminalTabBarMetrics.hoverAnimationDuration),
      value: TabInteractionKey(
        isHovering: isHovering,
        isActive: isActive,
        isPressing: isPressing,
        isDragging: isDragging
      )
    )
    .padding(.bottom, isActive ? TerminalTabBarMetrics.activeTabBottomPadding : 0)
    .offset(y: isActive ? TerminalTabBarMetrics.activeTabOffset : 0)
    .clipShape(.rect(cornerRadius: TerminalTabBarMetrics.tabCornerRadius))
    .contentShape(.rect)
    .onHover { hovering in
      isHovering = hovering
    }
    .simultaneousGesture(
      TapGesture(count: 2).onEnded {
        guard !tab.isTitleLocked else { return }
        onBeginRename()
      }
    )
    .onChange(of: isEditing) { _, editing in
      if editing {
        editingTitle = tab.displayTitle
        initialEditingTitle = tab.displayTitle
        cancelOnExit = false
        isFieldFocused = true
      } else if cancelOnExit {
        cancelOnExit = false
      } else if editingTitle != initialEditingTitle {
        onRename(editingTitle)
      }
    }
    .onDisappear {
      guard isEditing else { return }
      defer { onEndRename() }
      guard !cancelOnExit, editingTitle != initialEditingTitle else { return }
      onRename(editingTitle)
    }
    .zIndex(isActive ? 2 : (isDragging ? 3 : 0))
    .overlay {
      MiddleClickView(action: onClose)
    }
  }

  private var contentOpacity: Double {
    if isActive || isPressing || isDragging {
      return 1
    }
    return isHovering
      ? TerminalTabBarMetrics.inactiveContentOpacityHover
      : TerminalTabBarMetrics.inactiveContentOpacityIdle
  }

  private struct TabInteractionKey: Hashable {
    let isHovering: Bool
    let isActive: Bool
    let isPressing: Bool
    let isDragging: Bool
  }

  private var contentSaturation: Double {
    if isActive || isPressing || isDragging {
      return 1
    }
    return isHovering
      ? TerminalTabBarMetrics.inactiveContentSaturationHover
      : TerminalTabBarMetrics.inactiveContentSaturationIdle
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
