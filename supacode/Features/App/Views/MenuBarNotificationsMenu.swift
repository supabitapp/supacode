import AppKit
import ComposableArchitecture
import SupacodeSettingsFeature
import SupacodeSettingsShared
import SwiftUI

private let menuBarLogger = SupaLogger("MenuBar")

/// Contents of the menu bar extra: the sidebar's Pinned, Active, and Unread
/// rows, then quick actions. Rendered as a window rather than a native menu so
/// the rows can be the real `SidebarItemView`, with the same icon, title,
/// subtitle, notification and script dots, agent badges, and diff stats.
struct MenuBarNotificationsMenu: View {
  @Environment(\.openWindow) private var openWindow
  let store: StoreOf<AppFeature>

  var body: some View {
    let sections = store.repositories.menuBarSectionsCache
    let unreadCount = store.notificationIndicatorCount
    let repositories = store.scope(state: \.repositories, action: \.repositories)
    // The session list scrolls once it outgrows the screen so the action rows
    // below stay reachable; the action rows never scroll, exactly like a menu.
    VStack(alignment: .leading, spacing: 0) {
      MenuBarSessionList {
        if sections.isEmpty {
          Text("No Sessions Need Attention")
            .foregroundStyle(.secondary)
            .padding(.horizontal, MenuBarMetrics.rowPadding)
            .padding(.vertical, 5)
        } else {
          ForEach(sections.entries) { entry in
            MenuBarEntryRow(
              entry: entry,
              repositories: repositories,
              sections: sections,
              onOpen: openWorktree
            )
          }
        }
      }
      MenuBarDivider()
      MenuBarActionRow(
        title: unreadCount > 0
          ? "Mark \(unreadCount) Unread Notification\(unreadCount == 1 ? "" : "s") as Read"
          : "Mark Unread Notifications as Read",
        isEnabled: unreadCount > 0
      ) {
        dismissMenuBarExtra()
        store.send(.markAllNotificationsRead)
      }
      MenuBarActionRow(title: "Show Main Window") {
        showMainWindow()
      }
      MenuBarActionRow(title: "Settings...") {
        dismissMenuBarExtra()
        store.send(.settings(.setSelection(.general)))
        openWindow(id: WindowID.settings)
        NSApplication.shared.activate()
      }
      MenuBarDivider()
      MenuBarActionRow(title: "Quit Supacode") {
        // The quit confirmation is an alert hosted by the main window, so it
        // needs one on screen before it can be answered.
        showMainWindow()
        store.send(.requestQuit)
      }
    }
    .padding(.vertical, MenuBarMetrics.panelPadding)
    .frame(width: MenuBarMetrics.width)
    // Gives the rows' `ConcentricRectangle` highlight the panel's corners to
    // stay concentric with; nothing else supplies a container shape here.
    .containerShape(.rect(cornerRadius: MenuBarMetrics.panelCornerRadius))
  }

  private func openWorktree(_ worktreeID: Worktree.ID) {
    showMainWindow()
    store.send(.menuBarWorktreeSelected(worktreeID: worktreeID))
  }

  /// `openWindow` re-creates the scene the user closed, which `surfaceMainWindow()`
  /// cannot do (and it reports success after raising any other window, so it
  /// can't gate this either). Surfacing afterwards deminiaturizes it.
  private func showMainWindow() {
    dismissMenuBarExtra()
    openWindow(id: WindowID.main)
    NSApplication.shared.surfaceMainWindow()
  }

  /// Selecting anything must dismiss the whole menu bar extra, not just its
  /// panel: closing the panel window directly leaves the status item stuck
  /// highlighted, so the next click only deselects it. Clicking the status
  /// button toggles the extra off through the system, which closes the panel
  /// and clears the highlight together.
  private func dismissMenuBarExtra() {
    guard let button = Self.statusBarButton() else {
      // Defense in depth: if a future OS moves the status item out of reach the
      // panel would silently stay open on every selection, so make it loud.
      menuBarLogger.warning("Status item button not found; panel stays open on selection.")
      return
    }
    button.performClick(nil)
  }

  /// The menu bar extra's `NSStatusBarButton`, found by walking the app's
  /// windows. SwiftUI's `MenuBarExtra` never exposes its status item.
  private static func statusBarButton() -> NSStatusBarButton? {
    for window in NSApp.windows {
      if let button = statusBarButton(in: window.contentView) { return button }
    }
    return nil
  }

  private static func statusBarButton(in view: NSView?) -> NSStatusBarButton? {
    guard let view else { return nil }
    if let button = view as? NSStatusBarButton { return button }
    for subview in view.subviews {
      if let button = statusBarButton(in: subview) { return button }
    }
    return nil
  }
}

enum MenuBarMetrics {
  static let width: CGFloat = 320
  static let panelPadding: CGFloat = 5
  static let sectionSpacing: CGFloat = 6
  /// Inset of a row's content, matching where a menu starts its titles.
  static let rowPadding: CGFloat = 14
  /// Inset of a highlighted row from the panel edge, so its corners sit
  /// concentric with the panel's.
  static let highlightInset: CGFloat = 5
  /// The menu bar extra's window corner radius, which the system rounds the
  /// panel to but never exposes.
  static let panelCornerRadius: CGFloat = 14
  static let highlightCornerRadius = panelCornerRadius - highlightInset
  /// Height the session list caps at before it scrolls, leaving the action
  /// rows and a margin below the menu bar on screen.
  static var sessionListMaxHeight: CGFloat {
    let visibleHeight = NSScreen.main?.visibleFrame.height ?? 800
    return max(160, visibleHeight - 220)
  }
}

/// The session area. It hugs its content until that would run past the screen,
/// then caps and scrolls, so the pinned action rows below stay on screen no
/// matter how many worktrees are listed. `ViewThatFits` picks the plain stack
/// while it fits the cap and the scrolling one only once it doesn't, so short
/// lists never reserve empty height.
private struct MenuBarSessionList<Content: View>: View {
  let content: Content
  // The menu bar window proposes no height, so the list must carry an explicit
  // one: the rows' natural height until it hits the cap, then scroll. `nil`
  // (before the first measurement) falls back to the cap so rows always render
  // rather than collapsing to zero.
  @State private var contentHeight: CGFloat?

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        content
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .onGeometryChange(for: CGFloat.self, of: \.size.height) { contentHeight = $0 }
    }
    .frame(height: min(contentHeight ?? .infinity, MenuBarMetrics.sessionListMaxHeight))
    // No rubber-banding while everything fits.
    .scrollBounceBehavior(.basedOnSize)
  }
}

/// Full-bleed separator with the vertical breathing room a menu gives it.
private struct MenuBarDivider: View {
  var body: some View {
    Divider()
      .padding(.vertical, MenuBarMetrics.panelPadding)
  }
}

private struct MenuBarEntryRow: View {
  let entry: MenuBarEntry
  let repositories: StoreOf<RepositoriesFeature>
  let sections: MenuBarSections
  let onOpen: (Worktree.ID) -> Void

  var body: some View {
    switch entry.content {
    case .header(let title, let kind):
      MenuBarSectionHeader(title: title, dotColor: kind?.indicatorColor)
    case .worktree(let rowID):
      MenuBarWorktreeRowView(
        rowID: rowID,
        repositories: repositories,
        sections: sections,
        onOpen: onOpen
      )
    }
  }
}

/// Mirrors the sidebar's highlight header: the title plus the section's dot.
private struct MenuBarSectionHeader: View {
  let title: String
  let dotColor: Color?

  var body: some View {
    HStack(spacing: 4) {
      Text(title)
        .font(.caption)
        .fontWeight(.semibold)
        .foregroundStyle(.secondary)
      if let dotColor {
        SidebarHighlightHeaderDot(color: dotColor)
      }
    }
    .padding(.horizontal, MenuBarMetrics.rowPadding)
    .padding(.top, MenuBarMetrics.sectionSpacing)
    .padding(.bottom, 2)
  }
}

/// Scopes to the single leaf and renders the real sidebar row, so per-row
/// notification and agent churn invalidates only this row.
private struct MenuBarWorktreeRowView: View {
  let rowID: Worktree.ID
  let repositories: StoreOf<RepositoriesFeature>
  let sections: MenuBarSections
  let onOpen: (Worktree.ID) -> Void
  @State private var isHovering = false
  @Shared(.appStorage("worktreeRowHideSubtitleOnMatch")) private var hideSubtitleOnMatch = true

  var body: some View {
    if let itemStore = repositories.scope(
      state: \.sidebarItems[id: rowID],
      action: \.sidebarItems[id: rowID]
    ) {
      Button {
        onOpen(rowID)
      } label: {
        SidebarItemView(
          store: itemStore,
          hideSubtitle: false,
          hideSubtitleOnMatch: hideSubtitleOnMatch,
          showsPullRequestInfo: true,
          shortcutHint: nil,
          highlightSubtitle: sections.repositoryTagByID[itemStore.repositoryID]
        )
        .padding(.horizontal, MenuBarMetrics.rowPadding)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .menuBarRowHighlight(isHovering)
      .background(MenuBarRowHighlight(isHighlighted: isHovering))
      .onHover { isHovering = $0 }
    }
  }
}

/// Menu-style action row, sharing the worktree rows' highlight so the whole
/// panel reads as one menu.
private struct MenuBarActionRow: View {
  let title: String
  var isEnabled: Bool = true
  let action: () -> Void
  @State private var isHovering = false

  var body: some View {
    let isHighlighted = isHovering && isEnabled
    Button(action: action) {
      Text(title)
        .padding(.horizontal, MenuBarMetrics.rowPadding)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .disabled(!isEnabled)
    .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
    .menuBarRowHighlight(isHighlighted)
    .background(MenuBarRowHighlight(isHighlighted: isHighlighted))
    .onHover { isHovering = $0 }
  }
}

/// The menu's selection fill: accent-colored, inset from the panel edge, its
/// corners concentric with the panel's.
private struct MenuBarRowHighlight: View {
  let isHighlighted: Bool

  var body: some View {
    // A row in the middle of the panel is far from its corners, so concentricity
    // alone would round it to nothing: the floor is what actually shows.
    ConcentricRectangle(
      corners: .concentric(minimum: .fixed(MenuBarMetrics.highlightCornerRadius)),
      isUniform: true
    )
    .fill(isHighlighted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear))
    .padding(.horizontal, MenuBarMetrics.highlightInset)
  }
}

extension View {
  /// Flips the row's contents to their emphasized palette, the same way the
  /// sidebar recolors a selected row.
  fileprivate func menuBarRowHighlight(_ isHighlighted: Bool) -> some View {
    environment(\.backgroundProminence, isHighlighted ? .increased : .standard)
  }
}

/// Status item label: the app icon's "SC" monogram plus the unread count. A
/// status item renders only an image and text, so the count is text, not a
/// badge; the glyph is template-rendered so it tints to the menu bar.
struct MenuBarNotificationsLabel: View {
  let unreadCount: Int

  var body: some View {
    Label {
      Text(unreadCount > 0 ? "\(unreadCount)" : "")
        .monospacedDigit()
    } icon: {
      Image("MenuBarSC")
        .renderingMode(.template)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(maxHeight: .infinity)
    }
    .labelStyle(.titleAndIcon)
    .accessibilityLabel(
      unreadCount > 0
        ? "Supacode, \(unreadCount) unread notification\(unreadCount == 1 ? "" : "s")"
        : "Supacode"
    )
  }
}
