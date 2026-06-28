import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

public struct NotificationsSettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>

  public init(store: StoreOf<SettingsFeature>) {
    self.store = store
  }

  public var body: some View {
    Form {
      Section {
        Toggle(
          isOn: $store.systemNotificationsEnabled
        ) {
          Text("System notifications")
        }
        .help("Show macOS system notifications")
        Toggle(
          isOn: $store.notificationSoundEnabled
        ) {
          Text("Play notification sound")
          Text(
            "Ignored when system notifications are enabled, as they play sounds"
              + " according to your settings."
          )
        }.disabled(store.systemNotificationsEnabled)
        Picker(selection: $store.notificationSound) {
          ForEach(NotificationSound.allCases) { sound in
            Text(sound.displayName).tag(sound)
          }
        } label: {
          Text("Notification sound")
          Text(
            "Applies to in-app notifications. macOS banners only support System Default and "
              + "Supacode Chime; other sounds use the default."
          )
        }
        .help(
          "Sound for in-app notifications. macOS notification banners only support System Default and the "
            + "bundled Supacode Chime; other system sounds fall back to the default banner sound."
        )
      }
      Section("Worktrees") {
        Toggle(
          isOn: $store.inAppNotificationsEnabled
        ) {
          Text("Notification badge")
          Text("Display an orange dot next to worktrees with unread notifications.")
        }
        Toggle(
          isOn: $store.moveNotifiedWorktreeToTop
        ) {
          Text("Prioritize unread worktrees")
          Text("Worktrees with unread notifications will be shown first in the list.")
        }
      }
    }
    .formStyle(.grouped)
    .padding(.top, -20)
    .padding(.leading, -8)
    .padding(.trailing, -6)

    .navigationTitle("Notifications")
  }
}
