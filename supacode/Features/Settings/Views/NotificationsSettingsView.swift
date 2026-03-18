import ComposableArchitecture
import SwiftUI

struct NotificationsSettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>

  var body: some View {
    VStack(alignment: .leading) {
      Form {
        Section("Notifications") {
          Toggle(
            "Show bell icon next to worktree",
            isOn: $store.inAppNotificationsEnabled
          )
          .help("Show bell icon next to worktree")
          Toggle(
            "Play notification sound",
            isOn: $store.notificationSoundEnabled
          )
          .help("Play a sound when a notification is received")
          Toggle(
            "System notifications",
            isOn: $store.systemNotificationsEnabled
          )
          .help("Show macOS system notifications")
          Toggle(
            "Move notified worktree to top",
            isOn: $store.moveNotifiedWorktreeToTop
          )
          .help("Bring the worktree to the top when the terminal receives a notification")
        }
      }
      .formStyle(.grouped)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}
