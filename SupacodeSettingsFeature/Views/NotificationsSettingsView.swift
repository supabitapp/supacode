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
        Picker(selection: $store.notificationSound) {
          Text(NotificationSound.never.displayName).tag(NotificationSound.never)
          Divider()
          ForEach(NotificationSound.systemCases) { sound in
            NotificationSoundLabel(sound: sound).tag(sound)
          }
          Divider()
          Text(NotificationSound.supacodeClassic.displayName).tag(NotificationSound.supacodeClassic)
        } label: {
          Text("Play notification sound")
          Text(
            "Ignored when system notifications are enabled, as they play sounds"
              + " according to your settings."
          )
        }
        .disabled(store.systemNotificationsEnabled)
        Toggle(
          isOn: $store.muteNotificationsForActiveSurface
        ) {
          Text("Mute notifications for active surface")
          Text("Skip the notification and sound when the terminal that sent it is focused and visible.")
        }
        .disabled(!store.hasActiveNotificationChannel)
      }
      Section {
        Picker(selection: $store.notificationRetentionLimit) {
          ForEach(NotificationRetentionLimit.allCases, id: \.self) { limit in
            RetentionLimitLabel(limit: limit).tag(limit)
          }
        } label: {
          Text("Keep notifications")
          Text("Older notifications beyond this count are discarded per worktree.")
        }
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
          Text("Prioritize unread in Active and Pinned sections")
          Text("Worktrees with unread notifications will be shown first.")
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

private struct NotificationSoundLabel: View {
  let sound: NotificationSound

  var body: some View {
    if sound == GlobalSettings.default.notificationSound {
      Text("\(sound.displayName) \(Text("Default").foregroundStyle(.secondary))")
    } else {
      Text(sound.displayName)
    }
  }
}

private struct RetentionLimitLabel: View {
  let limit: NotificationRetentionLimit

  var body: some View {
    if limit == .defaultValue {
      Text("\(limit.label) \(Text("Default").foregroundStyle(.secondary))")
    } else {
      Text(limit.label)
    }
  }
}
