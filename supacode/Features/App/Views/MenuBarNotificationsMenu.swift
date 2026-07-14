import AppKit
import ComposableArchitecture
import SupacodeSettingsFeature
import SwiftUI

/// Contents of the menu bar extra: the worktrees that currently want attention
/// (unread notifications or an active agent) on top, then quick actions.
/// Rendered with the native `.menu` style, so rows are plain menu items
/// (title + subtitle Texts). It lists *which* sessions need attention rather
/// than repeating notification bodies — system notifications already carry
/// the message text.
struct MenuBarNotificationsMenu: View {
  let store: StoreOf<AppFeature>

  var body: some View {
    let list = MenuBarNotificationList.compute(rows: store.repositories.menuBarWorktreeRows())
    Group {
      if list.rows.isEmpty {
        Text("No Sessions Need Attention")
      } else {
        ForEach(list.rows) { row in
          Button {
            store.send(.menuBarWorktreeSelected(worktreeID: row.id))
          } label: {
            Text(row.worktreeName)
            Text(verbatim: subtitle(for: row))
          }
          .help("Open this worktree.")
        }
      }
      Divider()
      Button("Mark All as Read") {
        store.send(.markAllNotificationsRead)
      }
      .disabled(!list.hasUnread)
      .help("Mark every notification as read.")
      Button("Show Main Window") {
        NSApplication.shared.surfaceMainWindow()
      }
      .help("Bring the main Supacode window to the front.")
      Button("Settings...") {
        store.send(.settings(.setSelection(.general)))
      }
      .help("Open Supacode settings.")
      Divider()
      Button("Quit Supacode") {
        store.send(.requestQuit)
      }
      .help("Quit Supacode.")
    }
  }

  private func subtitle(for row: MenuBarWorktreeRow) -> String {
    var parts: [String] = [row.repoName]
    if row.unreadCount > 0 {
      parts.append(row.unreadCount == 1 ? "1 unread" : "\(row.unreadCount) unread")
    }
    if row.hasActiveAgent {
      parts.append("agent active")
    }
    return parts.joined(separator: " · ")
  }
}

/// Status item label: an "SC" monogram that adapts to the menu bar's light/dark
/// appearance, with a red dot while anything is unread. Kept as its own view so
/// notification churn invalidates just this label.
struct MenuBarNotificationsLabel: View {
  let store: StoreOf<AppFeature>

  var body: some View {
    let hasUnread = store.repositories.toolbarNotificationGroupsCache.contains { $0.unseenWorktreeCount > 0 }
    ZStack(alignment: .topTrailing) {
      Text("SC")
        .font(.system(size: 12, weight: .bold, design: .rounded))
      if hasUnread {
        Circle()
          .fill(.red)
          .frame(width: 5, height: 5)
          .offset(x: 4, y: -2)
      }
    }
    .accessibilityLabel(hasUnread ? "Supacode, unread notifications" : "Supacode")
  }
}
