import ComposableArchitecture
import SupacodeSettingsFeature
import SupacodeSettingsShared
import SwiftUI

struct UpdatesSettingsView: View {
  @Bindable var settingsStore: StoreOf<SettingsFeature>
  let updatesStore: StoreOf<UpdatesFeature>

  var body: some View {
    Form {
      Section {
        Picker(selection: $settingsStore.updateChannel) {
          Text("Stable").tag(UpdateChannel.stable)
          Text("Tip").tag(UpdateChannel.tip)
        } label: {
          Text("Channel")
          Text(
            settingsStore.updateChannel == .stable ? "Recommended for most users." : "Get the latest features early.")
        }
        Button {
          updatesStore.send(.checkForUpdates)
        } label: {
          Text("Check for Updates now")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .buttonBorderShape(.roundedRectangle)
      }
      Section("Automatic Updates") {
        Toggle(isOn: $settingsStore.updatesAutomaticallyCheckForUpdates) {
          Text("Check for updates automatically")
          Text("Periodically checks for new versions while Supacode is running.")
        }
        Toggle(isOn: $settingsStore.updatesAutomaticallyDownloadUpdates) {
          Text("Download and install updates automatically")
          Text("Downloads updates in the background. You will be prompted to restart to apply them.")
        }
        .disabled(!settingsStore.updatesAutomaticallyCheckForUpdates)
      }
    }
    .formStyle(.grouped)
    .padding(.top, -20)
    .padding(.leading, -8)
    .padding(.trailing, -6)
    .navigationTitle("Updates")
  }
}
