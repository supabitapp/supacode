import AppKit
import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

struct TerminalTabView: View {
  let tab: TerminalTabItem
  let isActive: Bool
  let isDragging: Bool
  let tabIndex: Int
  let fixedWidth: CGFloat?
  /// Per-tab scoped store. The view body reads exclusively from this for
  /// observation-tracked fields (agents, unseen count, progress display) so
  /// per-tab mutations invalidate only this leaf, not sibling tabs.
  let tabStore: StoreOf<TerminalTabFeature>
  let isLifecycleBusy: Bool
  let onSelect: () -> Void
  let onClose: () -> Void
  let onDismissSplitZoom: () -> Void
  let onRename: (String) -> Void
  @Binding var closeButtonGestureActive: Bool
  let isEditing: Bool
  let onBeginRename: () -> Void
  let onEndRename: () -> Void

  @State private var isHovering = false
  @State private var isPressing = false
  @State private var editingTitle = ""
  @State private var initialEditingTitle = ""
  @State private var cancelOnExit = false
  @FocusState private var isFieldFocused: Bool
  @Environment(CommandKeyObserver.self) private var commandKeyObserver
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    // The trailing slot is a layout sibling, so it takes only the width it needs and
    // gives the rest to the title.
    HStack(spacing: TerminalTabBarMetrics.contentSpacing) {
      TerminalTabLabelView(
        tab: tab,
        isActive: isActive,
        tabStore: tabStore,
        // Workspace-only lifecycle work has no owning surface; represent it on the selected tab only.
        isLifecycleRepresentative: isActive && isLifecycleBusy,
      )
      .allowsHitTesting(false)
      // The select button already carries the tab's label, so this would double-announce it.
      .accessibilityHidden(true)

      if hasTrailingContent {
        ZStack(alignment: .trailing) {
          if tab.isBlockingScriptCompleted {
            TerminalTabLockIndicator(
              suppress: suppressIdleIndicator
            )
          } else {
            TerminalTabNotificationIndicator(
              hasUnseenNotifications: hasUnseenNotifications,
              suppress: suppressIdleIndicator
            )
          }
          // At zero opacity it would still hold the slot open at the chord's width.
          if isShowingHint, let shortcutHint {
            TerminalTabShortcutHintText(hint: shortcutHint)
              .transition(.opacity)
          }
          if isSplitZoomed {
            TerminalTabTrailingButton(
              title: "Exit Split Zoom",
              systemImage: "arrow.up.right.and.arrow.down.left",
              ghosttyAction: "toggle_split_zoom",
              // Always offered while zoomed, unlike close, which waits for hover.
              isVisible: !isDragging && !isShowingHint,
              action: onDismissSplitZoom,
              gestureActive: $closeButtonGestureActive
            )
          } else {
            TerminalTabTrailingButton(
              title: "Close Tab",
              systemImage: "xmark",
              ghosttyAction: "close_tab",
              isVisible: isHovering && !isDragging && !isShowingHint,
              action: onClose,
              gestureActive: $closeButtonGestureActive
            )
          }
        }
        .frame(minWidth: TerminalTabBarMetrics.closeButtonSize, maxHeight: TerminalTabBarMetrics.closeButtonSize)
        .transition(.opacity)
      }
    }
    .padding(.horizontal, TerminalTabBarMetrics.tabHorizontalPadding)
    .animation(slotAnimation, value: isShowingHint)
    .animation(slotAnimation, value: hasTrailingContent)
    .opacity(isEditing ? 0 : 1)
    .allowsHitTesting(!isEditing)
    .frame(
      minWidth: TerminalTabBarMetrics.tabMinWidth,
      maxWidth: TerminalTabBarMetrics.tabMaxWidth,
      minHeight: TerminalTabBarMetrics.tabHeight,
      maxHeight: TerminalTabBarMetrics.tabHeight
    )
    .frame(width: fixedWidth)
    // Behind the content so the whole tab selects, not just the label.
    .background {
      Button(action: onSelect) {
        Color.clear.contentShape(.rect)
      }
      .buttonStyle(TerminalPressTrackingButtonStyle(isPressed: $isPressing))
      .accessibilityLabel(tab.displayTitle)
      .accessibilityValue(accessibilityValue)
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
        isDragging: isDragging
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
    // Stripe overlay sits AFTER `clipShape` with negative horizontal padding
    // so the tint paints over adjacent dividers; clipping otherwise leaves a
    // 1px gray notch at each side.
    .overlay(alignment: .top) {
      TerminalTabProgressStripe(
        isActive: isActive,
        isHovering: isHovering,
        isPressing: isPressing,
        isDragging: isDragging,
        tintColor: tab.tintColor,
        tabStore: tabStore
      )
    }
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
      } else if cancelOnExit {
        cancelOnExit = false
      } else if editingTitle != initialEditingTitle {
        onRename(editingTitle)
      }
    }
    // The double-click's Button action focuses the terminal after its gesture
    // fires. Defer one turn so the replacement field wins; tying the task to
    // edit state cancels a stale focus request when editing ends first.
    .task(id: isEditing) {
      guard isEditing else { return }
      await Task.yield()
      guard !Task.isCancelled else { return }
      isFieldFocused = true
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

  private var isSplitZoomed: Bool {
    tabStore.state.isSplitZoomed
  }

  private var shortcutHint: String? {
    commandKeyObserver.tabSelectionHint(atSlot: tabIndex)
  }

  /// Whether anything can occupy the trailing slot; false collapses it so the title gets
  /// the full width. Not gated on `isDragging`, which would reflow the tab under the pointer.
  private var hasTrailingContent: Bool {
    isShowingHint || isSplitZoomed || tab.isBlockingScriptCompleted || isHovering || hasUnseenNotifications
  }

  private var suppressIdleIndicator: Bool {
    isHovering || isDragging || isShowingHint || isSplitZoomed
  }

  private var hasUnseenNotifications: Bool {
    tabStore.state.hasUnseenNotifications
  }

  private var slotAnimation: Animation? {
    reduceMotion ? nil : .easeInOut(duration: TerminalTabBarMetrics.fadeAnimationDuration)
  }

  /// True when the cmd-pressed hotkey hint should occupy the trailing slot.
  /// Hover wins: when the user is over the tab the close button takes the
  /// slot regardless of whether ⌘ is also pressed.
  private var isShowingHint: Bool {
    commandKeyObserver.isPressed && shortcutHint != nil && !isHovering && !isDragging
  }

  /// State-aware accessibility value for VoiceOver. Restores the OSC-9 progress
  /// signal lost when `GhosttySurfaceProgressBar` was deleted: announces
  /// "Errored", "Paused", "Busy", or "47 percent complete" on the busy tab.
  private var accessibilityValue: String {
    tabStore.state.progressDisplay?.accessibilityValue ?? ""
  }
}

private struct TerminalTabShortcutHintText: View {
  let hint: String

  var body: some View {
    Text(hint)
      .font(.caption)
      // Explicit `.regular` because the tab bar lacks the sidebar's List/vibrancy
      // context, where `.font(.caption)` would otherwise render heavier.
      .fontWeight(.regular)
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .fixedSize()
  }
}

/// `suppress` hides the dot in the states the trailing slot is held for something else
/// (hover, drag, shortcut hint, split zoom).
private struct TerminalTabNotificationIndicator: View {
  let hasUnseenNotifications: Bool
  let suppress: Bool

  var body: some View {
    let isShowing = !suppress && hasUnseenNotifications
    TabNotificationDot()
      .opacity(isShowing ? 1 : 0)
      .allowsHitTesting(false)
      .animation(.easeInOut(duration: 0.2), value: isShowing)
  }
}

/// Idle-slot marker for blocking-script tabs. Sits in the same place as the
/// notification dot but never animates in/out from hover state because the
/// surface is permanently locked. `suppress` mirrors the dot's hide-on-hover
/// rules so close button and ⌘ hint always win.
private struct TerminalTabLockIndicator: View {
  let suppress: Bool

  var body: some View {
    Image(systemName: "lock.fill")
      .font(.caption2)
      .foregroundStyle(.secondary)
      .frame(width: TerminalTabBarMetrics.closeButtonSize, height: TerminalTabBarMetrics.closeButtonSize)
      .opacity(suppress ? 0 : 1)
      .allowsHitTesting(false)
      .accessibilityLabel("Locked tab")
      .animation(.easeInOut(duration: 0.2), value: suppress)
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
