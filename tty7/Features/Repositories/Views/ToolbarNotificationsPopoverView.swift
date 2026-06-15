import SwiftUI

struct ToolbarNotificationsPopoverView: View {
  let groups: [ToolbarNotificationRepositoryGroup]
  let onSelectNotification: (Worktree.ID, WorktreeTerminalNotification) -> Void
  let onDismissAll: () -> Void

  var body: some View {
    let notificationCount = groups.reduce(0) { count, repository in
      count + repository.notificationCount
    }
    let notificationLabel = notificationCount == 1 ? "notification" : "notifications"

    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text("Notifications")
              .font(.headline)
            Text("\(notificationCount) \(notificationLabel)")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button("Dismiss All") {
            onDismissAll()
          }
          .disabled(notificationCount == 0)
          .help("Dismiss all notifications")
        }

        ForEach(groups) { repository in
          VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text(repository.name)
              .font(.subheadline)
            ForEach(repository.worktrees) { worktree in
              VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                  Text(worktree.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                  if worktree.hasUnseenNotifications {
                    Circle()
                      .fill(.orange)
                      .frame(width: 6, height: 6)
                      .accessibilityHidden(true)
                  }
                }
                ForEach(worktree.notifications) { notification in
                  Button {
                    onSelectNotification(worktree.id, notification)
                  } label: {
                    HStack(alignment: .top, spacing: 8) {
                      Image(systemName: "bell")
                        .foregroundStyle(notification.isRead ? Color.secondary : Color.orange)
                        .accessibilityHidden(true)
                      Text(notification.content)
                        .font(.caption)
                        .foregroundStyle(notification.isRead ? Color.secondary : Color.primary)
                        .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                  }
                  .buttonStyle(.plain)
                  .help(
                    notification.content.isEmpty
                      ? "Select worktree and focus terminal"
                      : notification.content
                  )
                }
              }
            }
          }
        }
      }
      .padding()
    }
    .frame(minWidth: 320, maxWidth: 520, maxHeight: 440)
  }
}
