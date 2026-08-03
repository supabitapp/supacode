import ComposableArchitecture
import Foundation
import SupacodeSettingsShared
import SwiftUI
import UniformTypeIdentifiers

public struct NotificationsSettingsView: View {
  private static let supportedSoundTypes: [UTType] = [
    .aiff,
    .wav,
    UTType(filenameExtension: "caf"),
  ].compactMap { $0 }

  @Bindable var store: StoreOf<SettingsFeature>
  @State private var isChoosingCustomSound = false

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
        Picker(selection: $store.notificationSound) {
          Text(NotificationSound.never.displayName).tag(NotificationSound.never)
          Divider()
          ForEach(NotificationSound.systemCases) { sound in
            NotificationSoundLabel(sound: sound).tag(sound)
          }
          Divider()
          Text(NotificationSound.supacodeClassic.displayName).tag(NotificationSound.supacodeClassic)
          if let customSound = store.customNotificationSound {
            Divider()
            Text(customSound.displayName).tag(NotificationSound.custom)
          }
        } label: {
          Text("Play notification sound")
          Text(
            "For system notifications, macOS sounds use the default banner sound. "
              + "Custom and Supacode Classic apply directly when System Settings allows sounds."
          )
        }
        VStack(alignment: .leading) {
          HStack {
            Button(
              store.isManagingCustomNotificationSound ? "Working..." : "Choose Custom Sound..."
            ) {
              isChoosingCustomSound = true
            }
            .disabled(store.isManagingCustomNotificationSound)
            .help("Import an AIFF, WAV, or CAF notification sound")
            if store.customNotificationSound != nil {
              Button("Remove Custom Sound", role: .destructive) {
                store.send(.removeCustomNotificationSoundTapped)
              }
              .disabled(store.isManagingCustomNotificationSound)
              .help("Delete Supacode's managed copy of the custom notification sound")
            }
          }
          Text("AIFF, WAV, or CAF under 30 seconds (Linear PCM, IMA4, µLaw, or aLaw).")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        Toggle(
          isOn: $store.muteNotificationsForActiveSurface
        ) {
          Text("Mute notifications for active surface")
          Text(
            "Skip the notification and sound when the terminal that sent it is focused and visible."
          )
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
    .contentMargins(.trailing, 6, for: .scrollIndicators)
    .padding(.top, -20)
    .padding(.leading, -8)
    .padding(.trailing, -6)
    .navigationTitle("Notifications")
    .fileImporter(
      isPresented: $isChoosingCustomSound,
      allowedContentTypes: Self.supportedSoundTypes
    ) { result in
      switch result {
      case .success(let url):
        store.send(.customNotificationSoundSelected(url))
      case .failure(let error) where (error as? CocoaError)?.code == .userCancelled:
        break
      case .failure(let error):
        store.send(.customNotificationSoundImportFailed(error.localizedDescription))
      }
    }
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
