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
  let onSelect: () -> Void
  let onClose: () -> Void
  let onDismissSplitZoom: () -> Void
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
          tabStore: tabStore,
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
      .accessibilityValue(accessibilityValue)
      .allowsHitTesting(!isEditing)
      .opacity(isEditing ? 0 : 1)

      // Fixed 24pt trailing slot. Lock and notification dot are mutually exclusive;
      // the hint, close, and zoom-dismiss buttons cross-fade via opacity. Close/zoom
      // suppress lock/dot via the `suppress:` parameter when hovering, dragging,
      // hint-showing, or split-zoomed.
      ZStack(alignment: .trailing) {
        if tab.isBlockingScriptCompleted {
          TerminalTabLockIndicator(
            suppress: isHovering || isHoveringClose || isDragging || isShowingHint || isSplitZoomed
          )
        } else {
          TerminalTabNotificationIndicator(
            tabStore: tabStore,
            suppress: isHovering || isHoveringClose || isDragging || isShowingHint || isSplitZoomed
          )
        }
        if let shortcutHint {
          Text(shortcutHint)
            .font(.caption)
            // Explicit `.regular` because the tab bar lacks the sidebar's List/vibrancy
            // context, where `.font(.caption)` would otherwise render heavier.
            .fontWeight(.regular)
            .foregroundStyle(.secondary)
            .opacity(isShowingHint ? 1 : 0)
            .animation(.easeInOut(duration: TerminalTabBarMetrics.fadeAnimationDuration), value: isShowingHint)
        }
        if isSplitZoomed {
          TerminalTabExitSplitZoomButton(
            isDragging: isDragging,
            isShowingShortcutHint: isShowingHint,
            dismissAction: onDismissSplitZoom,
            closeButtonGestureActive: $closeButtonGestureActive
          )
        } else {
          TerminalTabCloseButton(
            isHoveringTab: isHovering,
            isDragging: isDragging,
            isShowingShortcutHint: isShowingHint,
            closeAction: onClose,
            closeButtonGestureActive: $closeButtonGestureActive,
            isHoveringClose: $isHoveringClose
          )
        }
      }
      .frame(width: TerminalTabBarMetrics.trailingSlotWidth, height: TerminalTabBarMetrics.closeButtonSize)
      .animation(.easeInOut(duration: TerminalTabBarMetrics.hoverAnimationDuration), value: isHovering)
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
            TerminalTabBarMetrics.trailingSlotWidth + TerminalTabBarMetrics.contentSpacing
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

  private var isSplitZoomed: Bool {
    tabStore.state.isSplitZoomed
  }

  private var shortcutHint: String? {
    let number = tabIndex + 1
    guard number > 0 && number <= 9 else { return nil }
    return "⌘\(number)"
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

/// Reads the tab's unread notification count off the per-tab scoped store.
/// `suppress` short-circuits the count check when the dot would be hidden
/// anyway (hover, drag, shortcut hint).
private struct TerminalTabNotificationIndicator: View {
  let tabStore: StoreOf<TerminalTabFeature>
  let suppress: Bool

  var body: some View {
    let isShowing = !suppress && tabStore.state.hasUnseenNotifications
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
      .help("Script finished. This tab is read-only and won't survive quitting Supacode.")
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
