import Sharing
import SupacodeSettingsShared
import SwiftUI

/// Trailing toolbar toggle for git / pull-request status, reusing the sidebar's
/// icon + check-status badge. Always tappable: it toggles the git inspector pane.
struct WorktreeGitStatusButton: View {
  let pullRequest: GithubPullRequest?
  let isSelected: Bool
  // Selection highlight color, derived from the terminal background luminance
  // so the lit state tracks the chrome instead of the system accent.
  let tint: Color
  // Concrete chrome foreground (white on dark, black on light) so the glyph
  // doesn't change color when the toggle is selected.
  let foreground: Color
  let onActivate: () -> Void
  @Shared(.settingsFile) private var settingsFile

  var body: some View {
    let icon = SidebarPullRequestIcon.resolve(pullRequest)
    let checkBadgeState = SidebarCheckBadgeState.resolve(pullRequest)
    let accessibilityLabel = checkBadgeState.map { "Pull request, \($0.statusDescription)" } ?? "Pull request"
    let shortcut = WorktreeDetailView.resolveShortcutDisplay(
      for: AppShortcuts.togglePullRequestInspector,
      overrides: settingsFile.global.shortcutOverrides
    )
    Toggle(isOn: Binding(get: { isSelected }, set: { _ in onActivate() })) {
      Label {
        Text("Pull Request")
      } icon: {
        WorktreePullRequestIconBadge(
          icon: icon,
          checkBadgeState: checkBadgeState,
          iconStyle: Self.iconStyle(for: icon, foreground: foreground, isSelected: isSelected),
          // Match the sidebar's muted main icon at rest; full strength only when the pane is open.
          iconOpacity: isSelected ? 1 : 0.6
        )
      }
    }
    .tint(tint)
    .help("Toggle Pull Request Inspector (\(shortcut))")
    .accessibilityLabel(accessibilityLabel)
  }

  // Pin the concrete chrome color only while selected (a lit toggle re-resolves
  // hierarchical styles against its tint); at rest fall back to the sidebar's own
  // colors (nil) so the icon reads identically to the sidebar.
  private static func iconStyle(
    for icon: SidebarPullRequestIcon,
    foreground: Color,
    isSelected: Bool
  ) -> AnyShapeStyle? {
    guard isSelected else { return nil }
    switch icon {
    case .branch: return AnyShapeStyle(foreground.opacity(0.65))
    case .draft: return AnyShapeStyle(foreground.opacity(0.45))
    case .open, .queued, .merged, .closed: return icon.color
    }
  }
}

/// The sidebar worktree icon with its corner check-status badge, reused in the
/// toolbar so both surfaces read identically.
struct WorktreePullRequestIconBadge: View {
  let icon: SidebarPullRequestIcon
  let checkBadgeState: SidebarCheckBadgeState?
  var size: CGFloat = 16
  // Style override for surfaces that can't rely on hierarchical resolution
  // (the selected toolbar toggle); defaults to the sidebar's own colors.
  var iconStyle: AnyShapeStyle?
  // Opacity for the main icon only; the status badge stays full, mirroring the sidebar.
  var iconOpacity: CGFloat = 1

  var body: some View {
    Image(icon.assetName)
      .renderingMode(.template)
      .resizable()
      .aspectRatio(contentMode: .fit)
      .foregroundStyle(iconStyle ?? icon.color)
      // Before the overlay, so only the main icon dims and the status badge stays full.
      .opacity(iconOpacity)
      .frame(width: size, height: size)
      .overlay(alignment: .bottomTrailing) {
        if let checkBadgeState {
          Image(systemName: checkBadgeState.symbolName)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .symbolVariant(.circle.fill)
            .symbolRenderingMode(.palette)
            .fontWeight(.black)
            .frame(width: 10, height: 10)
            .foregroundStyle(AnyShapeStyle(.windowBackground), AnyShapeStyle(checkBadgeState.color))
            .background(in: Circle())
            .accessibilityLabel(checkBadgeState.statusDescription)
            .offset(x: 2, y: 2)
        }
      }
      .accessibilityHidden(true)
  }
}

/// Trailing toolbar bell that toggles the notifications inspector pane. Switches
/// to `bell.badge` with an orange dot when there are unread notifications.
struct WorktreeNotificationsToolbarButton: View {
  let unreadCount: Int
  let isSelected: Bool
  // Selection highlight color, derived from the terminal background luminance
  // so the lit state tracks the chrome instead of the system accent.
  let tint: Color
  // Concrete chrome foreground (white on dark, black on light) so the glyph
  // doesn't change color when the toggle is selected.
  let foreground: Color
  let onActivate: () -> Void
  // Drives the unread bell body's fade: an explicit palette color can't inherit
  // the automatic window-key dim the plain bell gets for free.
  @Environment(\.controlActiveState) private var controlActiveState
  @Shared(.settingsFile) private var settingsFile

  var body: some View {
    let shortcut = WorktreeDetailView.resolveShortcutDisplay(
      for: AppShortcuts.toggleNotificationsInspector,
      overrides: settingsFile.global.shortcutOverrides
    )
    Toggle(isOn: Binding(get: { isSelected }, set: { _ in onActivate() })) {
      if unreadCount > 0 {
        // Palette keeps the badge dot orange; the bell body tracks the resting tint
        // and fades with the window, since palette can't inherit the automatic dim.
        Label("Notifications", systemImage: "bell.badge")
          .symbolRenderingMode(.palette)
          .foregroundStyle(.orange, bellBodyStyle)
      } else if isSelected {
        Label("Notifications", systemImage: "bell")
          .foregroundStyle(foreground)
      } else {
        // No foreground so the resting bell matches the other toolbar buttons exactly,
        // including the fade when the window isn't key.
        Label("Notifications", systemImage: "bell")
      }
    }
    .tint(tint)
    .help("Toggle Notifications Inspector (\(shortcut))")
    .accessibilityLabel(unreadCount > 0 ? "Notifications, \(unreadCount) unread" : "Notifications")
  }

  // Bell body for the unread `bell.badge` variant: chrome color when lit, else the
  // default label tint dropping to secondary whenever the window isn't key.
  private var bellBodyStyle: AnyShapeStyle {
    if isSelected { return AnyShapeStyle(foreground) }
    return controlActiveState == .key ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
  }
}
