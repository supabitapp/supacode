import SwiftUI

struct NotificationPopoverView: View {
  let notifications: [WorktreeTerminalNotification]
  @Environment(\.focusNotificationAction) private var focusNotificationAction: (WorktreeTerminalNotification) -> Void

  var body: some View {
    let count = notifications.count
    let countLabel = count == 1 ? "notification" : "notifications"
    ScrollView {
      VStack(alignment: .leading) {
        Text("Notifications")
          .font(.headline)
        Text("\(count) \(countLabel)")
          .font(.subheadline)
          .foregroundStyle(.secondary)
        Divider()
        ForEach(notifications) { notification in
          Button {
            focusNotificationAction(notification)
          } label: {
            HStack(alignment: .top) {
              Image(systemName: "bell")
                .foregroundStyle(notification.isRead ? Color.secondary : Color.orange)
                .accessibilityHidden(true)
              Text(notification.content)
                .foregroundStyle(notification.isRead ? Color.secondary : Color.primary)
                .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .buttonStyle(.plain)
          .font(.caption)
          .help(notification.content.isEmpty ? "Focus pane" : notification.content)
        }
      }
      .padding()
    }
    .frame(minWidth: 260, maxWidth: 480, maxHeight: 400)
  }
}
