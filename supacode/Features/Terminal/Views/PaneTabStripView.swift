import AppKit
import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI
import UniformTypeIdentifiers

nonisolated extension UTType {
  /// Private pasteboard type for tab drags, so dropping a tab on a terminal
  /// or another app transfers nothing readable.
  static let supacodeTabID = UTType(exportedAs: "sh.supacode.tabId")
}

/// The tab-drag pasteboard payload; a drop from another worktree's window
/// simply fails the local lookup and is ignored.
nonisolated struct PaneTabDragPayload: Codable, Sendable, Transferable {
  let tabID: UUID

  static var transferRepresentation: some TransferRepresentation {
    CodableRepresentation(contentType: .supacodeTabID)
  }
}

/// Tracks the tab an in-flight drag started from so a pane's drop zones can
/// gray out targets the drop would refuse. `.dropDestination`'s `isTargeted`
/// closure has no access to the payload, so the source is captured here at drag
/// start (the drag preview's `onAppear`) and shared across one worktree's panes.
@MainActor @Observable final class PaneTabDragModel {
  var sourceTabID: TabID?
}

/// One pane's tab strip: fixed-width tabs, dividers, overflow fades, and the
/// trailing accessories, with no background so the window tint shows through.
struct PaneTabStrip: View {
  let pane: Pane
  let isFocusedPane: Bool
  let isZoomed: Bool
  var isWindowed = false
  let isLifecycleBusy: Bool
  let store: StoreOf<LayoutFeature>
  let runtime: ContentRuntime
  let surfaceState: (UUID) -> WorktreeSurfaceState?
  /// Shared drag source, nil in a pane window; drives the split-zone graying.
  var dragModel: PaneTabDragModel?

  @Environment(\.controlActiveState) private var controlActiveState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.pixelLength) private var pixelLength
  @State private var scrollOffset: CGFloat = 0
  @State private var contentWidth: CGFloat = 0
  @State private var containerWidth: CGFloat = 0
  @State private var isAppendDropTargeted = false

  var body: some View {
    HStack(spacing: 0) {
      tabsScroller
      Spacer(minLength: 0)
      PaneTabStripAccessories(
        pane: pane,
        isZoomed: isZoomed,
        isWindowed: isWindowed,
        store: store,
        runtime: runtime
      )
    }
    .frame(height: TerminalTabBarMetrics.barHeight)
    .saturation(controlActiveState == .inactive ? 0 : 1)
    .clipped()
    .dropDestination(for: PaneTabDragPayload.self) { items, _ in
      // A drop on the strip body (past the tabs) appends to this pane.
      PaneTabDrag.performDrop(items, into: pane, at: pane.tabs.count, store: store, dragModel: dragModel)
    } isTargeted: {
      isAppendDropTargeted = $0
    }
  }

  private var tabsScroller: some View {
    GeometryReader { geometryProxy in
      ScrollViewReader { scrollReader in
        ScrollView(.horizontal) {
          tabsRow
            .background(
              GeometryReader { contentGeo in
                Color.clear
                  .onChange(of: contentGeo.frame(in: .named("tabScroll"))) { _, newFrame in
                    scrollOffset = -newFrame.minX
                    contentWidth = newFrame.width
                  }
                  .onAppear {
                    let frame = contentGeo.frame(in: .named("tabScroll"))
                    scrollOffset = -frame.minX
                    contentWidth = frame.width
                  }
              }
            )
        }
        .scrollIndicators(.never)
        .coordinateSpace(name: "tabScroll")
        .onAppear {
          containerWidth = geometryProxy.size.width
          if let selectedID = pane.selectedTabID {
            scrollReader.scrollTo(selectedID, anchor: .center)
          }
        }
        .onChange(of: geometryProxy.size.width) { _, newWidth in
          containerWidth = newWidth
        }
        .onChange(of: pane.selectedTabID) { _, newTabID in
          if let tabID = newTabID {
            withAnimation(.easeInOut(duration: TerminalTabBarMetrics.selectionAnimationDuration)) {
              scrollReader.scrollTo(tabID, anchor: .center)
            }
          }
        }
        .onChange(of: pane.tabs.count) { _, _ in
          // Re-center after the open/close animation settles, like the old bar.
          Task { @MainActor in
            try? await ContinuousClock().sleep(for: .seconds(TerminalTabBarMetrics.closeAnimationDuration))
            if let selectedID = pane.selectedTabID {
              withAnimation {
                scrollReader.scrollTo(selectedID)
              }
            }
          }
        }
      }
      .mask(overflowFadeMask)
    }
  }

  private var tabsRow: some View {
    HStack(alignment: .center, spacing: TerminalTabBarMetrics.tabSpacing) {
      ForEach(Array(pane.tabs.enumerated()), id: \.element.id) { index, tab in
        PaneTabView(
          tab: tab,
          pane: pane,
          isSelected: pane.selectedTabID == tab.id,
          isFocusedPane: isFocusedPane,
          isLifecycleBusy: isLifecycleBusy,
          tabIndex: index,
          fixedWidth: effectiveTabWidth,
          store: store,
          runtime: runtime,
          surfaceState: surfaceState,
          dragModel: dragModel
        )
        .id(tab.id)
        if index < pane.tabs.count - 1 {
          TerminalTabDivider()
        }
      }
    }
    .frame(height: TerminalTabBarMetrics.barHeight)
    .animation(
      reduceMotion ? nil : .easeOut(duration: TerminalTabBarMetrics.closeAnimationDuration),
      value: pane.tabs.ids
    )
    .overlay(alignment: .trailing) {
      if isAppendDropTargeted {
        PaneTabDropIndicator()
      }
    }
  }

  private var overflowFadeMask: some View {
    HStack(spacing: 0) {
      // Edge regions fade the tabs into transparency when the strip can
      // scroll further in that direction; otherwise stay fully opaque so
      // the first/last tab isn't clipped.
      LinearGradient(
        colors: [canScrollLeft ? .clear : .white, .white],
        startPoint: .leading,
        endPoint: .trailing
      )
      .frame(width: TerminalTabBarMetrics.overflowShadowWidth)
      Color.white.frame(maxWidth: .infinity)
      LinearGradient(
        colors: [.white, canScrollRight ? .clear : .white],
        startPoint: .leading,
        endPoint: .trailing
      )
      .frame(width: TerminalTabBarMetrics.overflowShadowWidth)
    }
    .animation(
      reduceMotion ? nil : .easeInOut(duration: TerminalTabBarMetrics.fadeAnimationDuration),
      value: canScrollLeft
    )
    .animation(
      reduceMotion ? nil : .easeInOut(duration: TerminalTabBarMetrics.fadeAnimationDuration),
      value: canScrollRight
    )
  }

  private var canScrollLeft: Bool {
    scrollOffset > 1
  }

  private var canScrollRight: Bool {
    contentWidth > containerWidth && scrollOffset < contentWidth - containerWidth - 1
  }

  private var effectiveTabWidth: CGFloat? {
    let count = pane.tabs.count
    guard containerWidth > 0, count > 0 else { return nil }
    // The row interleaves hairline dividers; exclude them or exactly-fitting
    // tabs measure a few pixels over and show a phantom overflow fade.
    let dividers = CGFloat(count - 1) * pixelLength
    let perTab = (containerWidth - dividers) / CGFloat(count)
    return min(
      TerminalTabBarMetrics.tabMaxWidth,
      max(TerminalTabBarMetrics.tabMinWidth, perTab)
    )
  }
}

/// Resolves tab-strip drag payloads into `moveTab` sends.
enum PaneTabDrag {
  @MainActor
  static func performDrop(
    _ items: [PaneTabDragPayload],
    into pane: Pane,
    at index: Int,
    store: StoreOf<LayoutFeature>,
    dragModel: PaneTabDragModel? = nil
  ) -> Bool {
    dragModel?.sourceTabID = nil
    guard let raw = items.first else { return false }
    let tabID = TabID(rawValue: raw.tabID)
    guard let sourcePane = store.layout.pane(containingTab: tabID) else { return false }
    var target = index
    if sourcePane.id == pane.id,
      let sourceIndex = sourcePane.tabs.index(id: tabID), sourceIndex < index
    {
      // The reducer removes the source before inserting; compensate so a
      // rightward drag still inserts before the tab it was dropped on.
      target -= 1
    }
    store.send(.moveTab(id: tabID, toPane: pane.id, index: target))
    return true
  }

  /// A drop on a pane's edge zone: the tab moves into a new pane split off
  /// the anchor.
  @MainActor
  static func performSplitDrop(
    _ items: [PaneTabDragPayload],
    anchor pane: Pane,
    direction: SplitTree<PaneID>.NewDirection,
    store: StoreOf<LayoutFeature>,
    dragModel: PaneTabDragModel? = nil
  ) -> Bool {
    dragModel?.sourceTabID = nil
    guard let raw = items.first else { return false }
    let tabID = TabID(rawValue: raw.tabID)
    guard let sourcePane = store.layout.pane(containingTab: tabID) else { return false }
    // A pane's only tab dropped on its own edge is a no-op reshuffle.
    guard sourcePane.id != pane.id || sourcePane.tabs.count > 1 else { return false }
    store.send(.moveTabToSplit(id: tabID, anchor: pane.id, direction: direction))
    return true
  }

  /// A drop near a shared divider: the tab moves into a new pane spanning both
  /// panes that share it (the anchor's parent split).
  @MainActor
  static func performSpanningSplitDrop(
    _ items: [PaneTabDragPayload],
    anchor pane: Pane,
    direction: SplitTree<PaneID>.NewDirection,
    store: StoreOf<LayoutFeature>,
    dragModel: PaneTabDragModel? = nil
  ) -> Bool {
    dragModel?.sourceTabID = nil
    guard let raw = items.first else { return false }
    let tabID = TabID(rawValue: raw.tabID)
    guard let sourcePane = store.layout.pane(containingTab: tabID) else { return false }
    guard sourcePane.id != pane.id || sourcePane.tabs.count > 1 else { return false }
    store.send(.moveTabToSpanningSplit(id: tabID, anchor: pane.id, direction: direction))
    return true
  }

  /// Whether a split drop of the dragged tab onto `pane`'s edge would take.
  /// A pane's only tab dropped on its own edge is refused; an unknown source
  /// (another window) can't be proven invalid, so it stays highlightable.
  @MainActor
  static func canSplitDrop(
    sourceTabID: TabID?,
    anchor pane: Pane,
    store: StoreOf<LayoutFeature>
  ) -> Bool {
    guard let sourceTabID, let sourcePane = store.layout.pane(containingTab: sourceTabID) else {
      return true
    }
    return sourcePane.id != pane.id || sourcePane.tabs.count > 1
  }
}

/// Accent capsule marking the insertion point of an in-flight tab drag.
private struct PaneTabDropIndicator: View {
  var body: some View {
    Capsule()
      .fill(TerminalTabBarColors.dropIndicator)
      .frame(
        width: TerminalTabBarMetrics.dropIndicatorWidth,
        height: TerminalTabBarMetrics.dropIndicatorHeight
      )
      .allowsHitTesting(false)
  }
}

/// The floating preview shown under the cursor while a tab is dragged.
private struct PaneTabDragPreview: View {
  let title: String

  var body: some View {
    Text(title)
      .font(.callout)
      .lineLimit(1)
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
  }
}

/// A single tab: the ported tab chrome (label, trailing slot, background,
/// stripe, hover/press states, inline rename, middle-click close) plus drag
/// between strips.
private struct PaneTabView: View {
  let tab: TabItem
  let pane: Pane
  let isSelected: Bool
  let isFocusedPane: Bool
  let isLifecycleBusy: Bool
  let tabIndex: Int
  let fixedWidth: CGFloat?
  let store: StoreOf<LayoutFeature>
  let runtime: ContentRuntime
  let surfaceState: (UUID) -> WorktreeSurfaceState?
  var dragModel: PaneTabDragModel?

  @State private var isHovering = false
  @State private var isPressing = false
  @State private var editingTitle = ""
  @State private var initialEditingTitle = ""
  @State private var cancelOnExit = false
  @State private var trailingButtonGestureActive = false
  @State private var isDropTargeted = false
  @FocusState private var isFieldFocused: Bool
  @Environment(CommandKeyObserver.self) private var commandKeyObserver
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var isEditing: Bool {
    store.editingTabID == tab.id
  }

  var body: some View {
    let _ = store.renderEpoch
    // Content-owned observable chrome: reads register per-tab observation, so
    // an agent storm or progress tick re-renders only this tab.
    let chrome = runtime.content(for: tab.content.id)?.chrome
    let isDormant = runtime.renderer(for: tab.content.id) == nil
    let progressDisplay = chrome?.progress
    let isLocked = chrome?.isLocked == true
    // The trailing slot is a layout sibling, so it takes only the width it
    // needs and gives the rest to the title.
    HStack(spacing: TerminalTabBarMetrics.contentSpacing) {
      PaneTabLabelView(
        tab: tab,
        isSelected: isSelected,
        isDormant: isDormant,
        accessory: chrome?.accessory,
        isShimmering: isShimmering(chrome: chrome, progressDisplay: progressDisplay)
      )
      .allowsHitTesting(false)
      // The select button already carries the tab's label, so this would
      // double-announce it.
      .accessibilityHidden(true)

      if hasTrailingContent(isLocked: isLocked) {
        ZStack(alignment: .trailing) {
          if isLocked {
            PaneTabLockIndicator(suppress: suppressIdleIndicator)
          } else {
            PaneTabNotificationIndicator(
              hasUnseenNotifications: hasUnseenNotifications,
              suppress: suppressIdleIndicator
            )
          }
          // At zero opacity it would still hold the slot open at the chord's width.
          if isShowingHint, let shortcutHint {
            PaneTabShortcutHintText(hint: shortcutHint)
              .transition(.opacity)
          }
          TerminalTabTrailingButton(
            title: "Close Tab",
            systemImage: "xmark",
            shortcut: AppShortcuts.closeTab,
            isVisible: isHovering && !isShowingHint,
            action: requestClose,
            gestureActive: $trailingButtonGestureActive
          )
        }
        .frame(minWidth: TerminalTabBarMetrics.closeButtonSize, maxHeight: TerminalTabBarMetrics.closeButtonSize)
        .transition(.opacity)
      }
    }
    .padding(.horizontal, TerminalTabBarMetrics.tabHorizontalPadding)
    .animation(slotAnimation, value: isShowingHint)
    .animation(slotAnimation, value: hasTrailingContent(isLocked: isLocked))
    .opacity(isEditing ? 0 : 1)
    .allowsHitTesting(!isEditing)
    .frame(
      minWidth: TerminalTabBarMetrics.tabMinWidth,
      maxWidth: TerminalTabBarMetrics.tabMaxWidth,
      minHeight: TerminalTabBarMetrics.tabHeight,
      maxHeight: TerminalTabBarMetrics.tabHeight
    )
    .frame(width: fixedWidth)
    // Behind the content so the whole tab selects, not just the label. The
    // drag handle rides the same layer, so the trailing controls (which
    // hit-test above it) can never start a drag.
    .background {
      Button {
        store.send(.selectTab(id: tab.id))
      } label: {
        Color.clear.contentShape(.rect)
      }
      .buttonStyle(TerminalPressTrackingButtonStyle(isPressed: $isPressing))
      .accessibilityLabel(displayTitle)
      .accessibilityValue(progressDisplay?.accessibilityValue ?? "")
      .allowsHitTesting(!isEditing)
      .draggable(PaneTabDragPayload(tabID: tab.id.rawValue)) {
        // The preview appears at drag start; capturing the source here lets the
        // pane split zones gray out drops this tab can't take.
        PaneTabDragPreview(title: displayTitle)
          .onAppear { dragModel?.sourceTabID = tab.id }
      }
    }
    .overlay {
      if isEditing {
        renameField
      }
    }
    .opacity(contentOpacity)
    .saturation(contentSaturation)
    .background {
      TerminalTabBackground(
        isActive: isSelected,
        isHovering: isHovering,
        isPressing: isPressing,
        isDragging: false
      )
    }
    .animation(
      reduceMotion ? nil : .easeInOut(duration: TerminalTabBarMetrics.hoverAnimationDuration),
      value: TabInteractionKey(isHovering: isHovering, isSelected: isSelected, isPressing: isPressing)
    )
    .padding(.bottom, isSelected ? TerminalTabBarMetrics.activeTabBottomPadding : 0)
    .offset(y: isSelected ? TerminalTabBarMetrics.activeTabOffset : 0)
    .clipShape(.rect(cornerRadius: TerminalTabBarMetrics.tabCornerRadius))
    // Stripe overlay sits AFTER `clipShape` with negative horizontal padding
    // so the tint paints over adjacent dividers; clipping otherwise leaves a
    // 1px gray notch at each side.
    .overlay(alignment: .top) {
      PaneTabStripe(
        isSelected: isSelected,
        isHovering: isHovering,
        isPressing: isPressing,
        tintColor: tab.tintColor,
        progressDisplay: progressDisplay
      )
    }
    .contentShape(.rect)
    .onHover { hovering in
      isHovering = hovering
    }
    .simultaneousGesture(
      TapGesture(count: 2).onEnded {
        beginRename()
      }
    )
    .onChange(of: isEditing) { _, editing in
      if editing {
        editingTitle = displayTitle
        initialEditingTitle = displayTitle
        cancelOnExit = false
      } else if cancelOnExit {
        cancelOnExit = false
      } else if editingTitle != initialEditingTitle {
        // An empty commit clears the override on every commit path.
        store.send(.renameTab(id: tab.id, title: editingTitle))
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
      defer { store.send(.endTabRename) }
      guard !cancelOnExit, editingTitle != initialEditingTitle else { return }
      store.send(.renameTab(id: tab.id, title: editingTitle))
    }
    .zIndex(isSelected ? 2 : 0)
    .overlay {
      MiddleClickView(action: requestClose)
    }
    .overlay(alignment: .leading) {
      // Dropping on a tab inserts before it.
      if isDropTargeted {
        PaneTabDropIndicator()
      }
    }
    .dropDestination(for: PaneTabDragPayload.self) { items, _ in
      guard let index = pane.tabs.index(id: tab.id) else { return false }
      return PaneTabDrag.performDrop(items, into: pane, at: index, store: store, dragModel: dragModel)
    } isTargeted: {
      isDropTargeted = $0
    }
    .contextMenu { contextMenuItems }
  }

  private var displayTitle: String {
    tab.customTitle ?? tab.title
  }

  private var contentOpacity: Double {
    if isSelected || isPressing {
      return 1
    }
    return isHovering
      ? TerminalTabBarMetrics.inactiveContentOpacityHover
      : TerminalTabBarMetrics.inactiveContentOpacityIdle
  }

  private var contentSaturation: Double {
    if isSelected || isPressing {
      return 1
    }
    return isHovering
      ? TerminalTabBarMetrics.inactiveContentSaturationHover
      : TerminalTabBarMetrics.inactiveContentSaturationIdle
  }

  private struct TabInteractionKey: Hashable {
    let isHovering: Bool
    let isSelected: Bool
    let isPressing: Bool
  }

  /// Progress and blocking-script activity shimmer like agent work; workspace
  /// lifecycle work is represented on the focused pane's selected tab only.
  private func isShimmering(
    chrome: (any TabChrome)?,
    progressDisplay: TerminalTabProgressDisplay?
  ) -> Bool {
    chrome?.isWorking == true
      || progressDisplay != nil
      || (isSelected && isFocusedPane && isLifecycleBusy)
  }

  private var shortcutHint: String? {
    commandKeyObserver.tabSelectionHint(atSlot: tabIndex)
  }

  /// Whether anything can occupy the trailing slot; false collapses it so the
  /// title gets the full width.
  private func hasTrailingContent(isLocked: Bool) -> Bool {
    isShowingHint || isLocked || isHovering || hasUnseenNotifications
  }

  private var suppressIdleIndicator: Bool {
    isHovering || isShowingHint
  }

  private var hasUnseenNotifications: Bool {
    surfaceState(tab.content.id.rawValue)?.hasUnseenNotification == true
  }

  private var slotAnimation: Animation? {
    reduceMotion ? nil : .easeInOut(duration: TerminalTabBarMetrics.fadeAnimationDuration)
  }

  /// True when the cmd-pressed hotkey hint should occupy the trailing slot.
  /// Only the focused pane's tabs answer `goto_tab`, so only they hint. Hover
  /// wins: the close button takes the slot regardless of ⌘.
  private var isShowingHint: Bool {
    isFocusedPane && commandKeyObserver.isPressed && shortcutHint != nil && !isHovering
  }

  private var renameField: some View {
    TextField("", text: $editingTitle)
      .textFieldStyle(.plain)
      .font(.caption)
      .focused($isFieldFocused)
      .foregroundStyle(TerminalTabBarColors.activeText)
      .accessibilityLabel("Rename tab")
      .padding(.horizontal, TerminalTabBarMetrics.tabHorizontalPadding)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
      .onSubmit { store.send(.endTabRename) }
      .onExitCommand {
        cancelOnExit = true
        store.send(.endTabRename)
      }
      .onChange(of: isFieldFocused) { _, focused in
        guard !focused, isEditing else { return }
        store.send(.endTabRename)
      }
  }

  @ViewBuilder
  private var contextMenuItems: some View {
    if !tab.isTitleLocked {
      Button("Rename Tab") { beginRename() }
      Divider()
    }
    Button("Close Tab", action: requestClose)
    Button("Close Other Tabs") {
      store.send(.contentRequestedClose(content: tab.content.id, scope: .otherTabs))
    }
    .disabled(pane.tabs.count <= 1)
    Button("Close Tabs to the Right") {
      store.send(.contentRequestedClose(content: tab.content.id, scope: .tabsToTheRight))
    }
    .disabled(pane.tabs.last?.id == tab.id)
    Button("Close All") {
      store.send(.contentRequestedClose(content: tab.content.id, scope: .allTabs))
    }
  }

  private func requestClose() {
    // Through the confirm gate: the three-way close-tab mode decides whether
    // this needs an alert.
    store.send(.contentRequestedClose(content: tab.content.id, scope: .tab))
  }

  private func beginRename() {
    guard !tab.isTitleLocked else { return }
    store.send(.beginTabRename(id: tab.id))
  }
}

/// The tab's leading content: dormant marker, content accessory, icon, and
/// title.
private struct PaneTabLabelView: View {
  let tab: TabItem
  let isSelected: Bool
  let isDormant: Bool
  let accessory: AnyView?
  let isShimmering: Bool

  var body: some View {
    HStack(spacing: TerminalTabBarMetrics.contentSpacing) {
      if isDormant {
        // Semibold compensates for the zzz glyph's thin strokes.
        Image(systemName: "zzz")
          .imageScale(.small)
          .fontWeight(.semibold)
          .foregroundStyle(.secondary)
          .frame(
            width: TerminalTabBarMetrics.closeButtonSize,
            height: TerminalTabBarMetrics.closeButtonSize
          )
          .accessibilityLabel("Hibernated tab")
          .help("Hibernated to save resources. Select to reconnect.")
      }
      if let accessory {
        accessory
      }
      if let icon = tab.icon {
        Image(systemName: icon)
          .imageScale(.small)
          .foregroundStyle(tab.tintColor?.color ?? TerminalTabBarColors.activeText)
          .frame(
            width: TerminalTabBarMetrics.closeButtonSize,
            height: TerminalTabBarMetrics.closeButtonSize
          )
          .accessibilityHidden(true)
      }
      PaneTabTitleLabel(
        title: tab.customTitle ?? tab.title,
        isSelected: isSelected,
        isShimmering: isShimmering
      )
      .equatable()
      Spacer(minLength: TerminalTabBarMetrics.contentTrailingSpacing)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
  }
}

/// Equatable barrier around the shimmering title: a busy trigger that doesn't
/// change the title / selection inputs skips this leaf, so the shimmer sweep
/// keeps running uninterrupted instead of re-rendering per report.
private struct PaneTabTitleLabel: View, Equatable {
  let title: String
  let isSelected: Bool
  let isShimmering: Bool

  var body: some View {
    Text(title)
      .font(.caption)
      .fontWeight(isSelected ? .semibold : .regular)
      .lineLimit(1)
      .foregroundStyle(TerminalTabBarColors.activeText)
      .shimmer(isActive: isShimmering)
  }
}

private struct PaneTabShortcutHintText: View {
  let hint: String

  var body: some View {
    Text(hint)
      .font(.caption)
      // Explicit `.regular` because the tab bar lacks the sidebar's
      // List/vibrancy context, where `.font(.caption)` would otherwise render
      // heavier.
      .fontWeight(.regular)
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .fixedSize()
  }
}

/// `suppress` hides the dot while the trailing slot is held for something
/// else (hover, shortcut hint).
private struct PaneTabNotificationIndicator: View {
  let hasUnseenNotifications: Bool
  let suppress: Bool

  var body: some View {
    let isShowing = !suppress && hasUnseenNotifications
    Circle()
      .fill(.orange)
      .frame(width: 6, height: 6)
      .frame(width: TerminalTabBarMetrics.closeButtonSize, height: TerminalTabBarMetrics.closeButtonSize)
      .accessibilityLabel("Unread notifications")
      .opacity(isShowing ? 1 : 0)
      .allowsHitTesting(false)
      .animation(.easeInOut(duration: 0.2), value: isShowing)
  }
}

/// Idle-slot marker for a completed blocking-script tab; mirrors the dot's
/// hide-on-hover rules so the close button and ⌘ hint always win.
private struct PaneTabLockIndicator: View {
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

/// Top-of-tab colored stripe carrying both the tint indicator and the OSC-9
/// progress signal, painted over the adjacent dividers via `-pixelLength`
/// horizontal padding so the active tab reads continuous across boundaries.
private struct PaneTabStripe: View {
  let isSelected: Bool
  let isHovering: Bool
  let isPressing: Bool
  let tintColor: RepositoryColor?
  let progressDisplay: TerminalTabProgressDisplay?

  @Environment(\.pixelLength) private var pixelLength

  var body: some View {
    ZStack(alignment: .leading) {
      Rectangle()
        .fill(isDeterminate ? color.opacity(0.3) : color)
      if case .determinate(let percent) = progressDisplay?.style {
        // scaleEffect composites the fill (no relayout); the percent is
        // bucketed upstream so agent ticks don't thrash layout.
        Rectangle()
          .fill(color)
          .scaleEffect(x: CGFloat(max(0, min(percent, 100))) / 100, anchor: .leading)
      }
    }
    .frame(maxWidth: .infinity)
    .frame(height: TerminalTabBarMetrics.activeIndicatorHeight)
    .padding(.horizontal, -pixelLength)
    .opacity(stripeOpacity)
    .allowsHitTesting(false)
  }

  private var stripeOpacity: Double {
    // The untinted fallback carries its own dimming via `.secondary`, so the
    // active tab paints at full opacity regardless.
    if isSelected {
      return 1
    }
    // Inactive untinted tabs with no progress signal stay hidden.
    guard tintColor != nil || progressDisplay != nil else { return 0 }
    if isPressing { return 1 }
    return isHovering
      ? TerminalTabBarMetrics.inactiveContentOpacityHover
      : TerminalTabBarMetrics.inactiveContentOpacityIdle
  }

  private var isDeterminate: Bool {
    if case .determinate = progressDisplay?.style { return true }
    return false
  }

  /// Progress states override the tab tint; the untinted fallback paints
  /// `.secondary` so the selected indicator stays visible without an
  /// accent-color flash.
  private var color: Color {
    switch progressDisplay?.style {
    case .error: .red
    case .paused: .orange
    case .indeterminate, .determinate: tintColor?.color ?? .accentColor
    case nil: tintColor?.color ?? .secondary
    }
  }
}

/// The strip's trailing accessories: the exit-zoom button (zoomed panes only)
/// and the new-tab menu carrying the splits and the window-mode toggle.
private struct PaneTabStripAccessories: View {
  let pane: Pane
  let isZoomed: Bool
  let isWindowed: Bool
  let store: StoreOf<LayoutFeature>
  let runtime: ContentRuntime

  var body: some View {
    HStack(spacing: TerminalTabBarMetrics.contentTrailingSpacing) {
      // Zoom is pane-level state, so its exit control belongs to the strip.
      if isZoomed {
        PaneTabStripAccessoryButton(
          title: "Exit Split Zoom",
          systemImage: "arrow.down.right.and.arrow.up.left",
          shortcut: AppShortcuts.toggleSplitZoom,
          action: { store.send(.toggleZoom(paneID: pane.id)) }
        )
      }
      PaneTabStripNewTabControl(
        canSplit: !isWindowed && selectedLiveContentID != nil,
        isWindowed: isWindowed,
        newTab: requestNewTab,
        split: requestSplit,
        toggleWindowMode: toggleWindowMode
      )
      .disabled(pane.selectedTab == nil)
    }
    .frame(height: TerminalTabBarMetrics.barHeight)
    .padding(.trailing, 8)
  }

  private var selectedLiveContentID: ContentID? {
    guard let contentID = pane.selectedTab?.content.id,
      runtime.renderer(for: contentID) != nil
    else { return nil }
    return contentID
  }

  private func requestNewTab() {
    guard let contentID = pane.selectedTab?.content.id else { return }
    store.send(.contentRequestedNewTab(content: contentID))
  }

  private func requestSplit(_ direction: TerminalSplitMenuDirection) {
    guard let contentID = selectedLiveContentID else { return }
    store.send(.contentRequestedSplit(content: contentID, direction: direction.paneDirection))
  }

  private func toggleWindowMode() {
    store.send(isWindowed ? .exitWindowMode(paneID: pane.id) : .enterWindowMode(paneID: pane.id))
  }
}

/// The new-tab split control, mirroring the window toolbar's split buttons:
/// the `+` opens a tab on click, the adjacent chevron opens the splits and
/// window-mode menu on click, with no press-and-hold.
private struct PaneTabStripNewTabControl: View {
  let canSplit: Bool
  let isWindowed: Bool
  let newTab: () -> Void
  let split: (TerminalSplitMenuDirection) -> Void
  let toggleWindowMode: () -> Void

  @Shared(.settingsFile) private var settingsFile

  var body: some View {
    HStack(spacing: 0) {
      PaneTabStripAccessoryButton(
        title: "New Tab",
        systemImage: "plus",
        shortcut: AppShortcuts.newTerminalTab,
        action: newTab
      )
      Menu {
        ForEach(TerminalSplitMenuDirection.allCases, id: \.self) { direction in
          Button(direction.title, systemImage: direction.systemImage) {
            split(direction)
          }
          .appKeyboardShortcut(direction.appShortcut.effective(from: settingsFile.global.shortcutOverrides))
          .disabled(!canSplit)
        }
        Divider()
        Button(
          isWindowed ? "Return to Main Window" : "Move to New Window",
          systemImage: "macwindow.on.rectangle",
          action: toggleWindowMode
        )
        .appKeyboardShortcut(AppShortcuts.toggleWindowMode.effective(from: settingsFile.global.shortcutOverrides))
      } label: {
        Image(systemName: "chevron.down")
          .imageScale(.small)
          .font(.caption2)
          // Narrower than the `+` so the pair reads as one split control.
          .frame(minWidth: 16, minHeight: TerminalTabBarMetrics.barHeight)
          .contentShape(.rect)
          .accessibilityLabel("Splits and Window Mode")
      }
      .menuStyle(.secondaryToolbar)
      .help("Splits and Window Mode")
    }
  }
}

extension TerminalSplitMenuDirection {
  fileprivate var paneDirection: SplitTree<PaneID>.NewDirection {
    switch self {
    case .right: .right
    case .left: .left
    case .down: .down
    case .up: .top
    }
  }
}

private struct PaneTabStripAccessoryButton: View {
  let title: String
  let systemImage: String
  let shortcut: AppShortcut
  let action: () -> Void

  @Shared(.settingsFile) private var settingsFile

  var body: some View {
    let shortcut = shortcut.effective(from: settingsFile.global.shortcutOverrides)?.display

    Button(action: action) {
      Label(title, systemImage: systemImage)
        .labelStyle(.iconOnly)
        .frame(minWidth: TerminalTabBarMetrics.barHeight, minHeight: TerminalTabBarMetrics.barHeight)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .help(helpText(shortcut: shortcut))
  }

  private func helpText(shortcut: String?) -> String {
    guard let shortcut else { return title }
    return "\(title) (\(shortcut))"
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
