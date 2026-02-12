import ComposableArchitecture
import SwiftUI

struct UpdatesSettingsView: View {
  @Bindable var settingsStore: StoreOf<SettingsFeature>
  let updatesStore: StoreOf<UpdatesFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Form {
        Section("Update Channel") {
          Picker("Channel", selection: $settingsStore.updateChannel) {
            Text("Stable").tag(UpdateChannel.stable)
            Text("Tip").tag(UpdateChannel.tip)
          }
        }
        Section("Automatic Updates") {
          Toggle(
            "Check for updates automatically",
            isOn: $settingsStore.updatesAutomaticallyCheckForUpdates
          )
          Toggle(
            "Download and install updates automatically",
            isOn: $settingsStore.updatesAutomaticallyDownloadUpdates
          )
          .disabled(!settingsStore.updatesAutomaticallyCheckForUpdates)
        }
      }
      .formStyle(.grouped)

      HStack {
        Button("Check for Updates Now") {
          updatesStore.send(.checkForUpdates)
        }
        .help("Check for Updates (\(AppShortcuts.checkForUpdates.display))")
        Spacer()
      }
      .padding(.top)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}
