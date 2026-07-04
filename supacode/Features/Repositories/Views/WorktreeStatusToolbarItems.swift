import SupacodeSettingsShared
import SwiftUI

/// Trailing toolbar toggle for git / pull-request status, reusing the sidebar's
/// icon + check-status badge. Always tappable: it opens the git inspector pane.
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

  var body: some View {
    let icon = SidebarPullRequestIcon.resolve(pullRequest)
    let checkBadgeState = SidebarCheckBadgeState.resolve(pullRequest)
    let accessibilityLabel = checkBadgeState.map { "Pull request, \($0.statusDescription)" } ?? "Pull request"
    let shortcut = WorktreeDetailView.resolveShortcutDisplay(for: AppShortcuts.togglePullRequestInspector)
    Toggle(isOn: Binding(get: { isSelected }, set: { _ in onActivate() })) {
      Label {
        Text("Pull Request")
      } icon: {
        WorktreePullRequestIconBadge(
          icon: icon,
          checkBadgeState: checkBadgeState,
          iconStyle: Self.iconStyle(for: icon, foreground: foreground)
        )
      }
    }
    .tint(tint)
    .help("Toggle Pull Request Inspector (\(shortcut))")
    .accessibilityLabel(accessibilityLabel)
  }

  // Hierarchical styles (`.secondary` / `.tertiary`) re-resolve inside the
  // selected toggle; substitute concrete chrome-derived colors for them.
  private static func iconStyle(for icon: SidebarPullRequestIcon, foreground: Color) -> AnyShapeStyle {
    switch icon {
    case .branch: AnyShapeStyle(foreground.opacity(0.65))
    case .draft: AnyShapeStyle(foreground.opacity(0.45))
    case .open, .queued, .merged, .closed: icon.color
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

  var body: some View {
    Image(icon.assetName)
      .renderingMode(.template)
      .resizable()
      .aspectRatio(contentMode: .fit)
      .foregroundStyle(iconStyle ?? icon.color)
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

  var body: some View {
    let shortcut = WorktreeDetailView.resolveShortcutDisplay(for: AppShortcuts.toggleNotificationsInspector)
    Toggle(isOn: Binding(get: { isSelected }, set: { _ in onActivate() })) {
      // Palette orange is scoped to the badge variant; on the plain bell the
      // first palette style would paint the whole symbol orange.
      if unreadCount > 0 {
        Label("Notifications", systemImage: "bell.badge")
          .symbolRenderingMode(.palette)
          .foregroundStyle(.orange, foreground)
      } else {
        Label("Notifications", systemImage: "bell")
          .foregroundStyle(foreground)
      }
    }
    .tint(tint)
    .help("Toggle Notifications Inspector (\(shortcut))")
    .accessibilityLabel(unreadCount > 0 ? "Notifications, \(unreadCount) unread" : "Notifications")
  }
}
