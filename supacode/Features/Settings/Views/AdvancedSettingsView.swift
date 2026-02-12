import ComposableArchitecture
import Foundation
import SwiftUI

struct AdvancedSettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>

  var body: some View {
    let supacodeHomeDirectoryOverrideDraft = Binding(
      get: { store.supacodeHomeDirectoryOverrideDraft },
      set: { store.send(.supacodeHomeDirectoryDraftChanged($0)) }
    )
    let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
    let isEnvironmentOverrideActive: Bool =
      if let environmentOverride = ProcessInfo.processInfo.environment[
        SupacodePaths.homeOverrideEnvironmentKey
      ] {
        SupacodePaths.normalizedBaseDirectoryOverride(environmentOverride, homeDirectory: homeDirectory) != nil
      } else {
        false
      }
    VStack(alignment: .leading) {
      Form {
        Section("Storage") {
          VStack(alignment: .leading, spacing: 8) {
            Text("Current storage directory")
              .foregroundStyle(.secondary)
            Text(store.effectiveSupacodeHomeDirectoryPath)
              .font(.body.monospaced())
              .textSelection(.enabled)
          }
          TextField(
            "Custom storage directory (empty means default)",
            text: supacodeHomeDirectoryOverrideDraft
          )
          HStack {
            Button("Apply") {
              store.send(.applySupacodeHomeDirectoryOverride)
            }
            .help("Apply custom Supacode storage directory (no shortcut)")
            Button("Reset to Default") {
              store.send(.resetSupacodeHomeDirectoryOverride)
            }
            .help("Reset Supacode storage directory to default (no shortcut)")
          }
          if let error = store.supacodeHomeDirectoryValidationError {
            Text(error)
              .foregroundStyle(.red)
          }
          if isEnvironmentOverrideActive {
            Text("SUPACODE_HOME is active for this launch and overrides the saved value.")
              .foregroundStyle(.secondary)
          }
          if store.isSupacodeHomeDirectoryRestartRequired {
            Text("Restart Supacode to apply storage directory changes.")
              .foregroundStyle(.secondary)
          }
        }
        Section("Advanced") {
          VStack(alignment: .leading) {
            Toggle(
              "Share analytics with Supacode",
              isOn: $store.analyticsEnabled
            )
            .help("Share anonymous usage data with Supacode (requires restart)")
            Text("Anonymous usage data helps improve Supacode.")
              .foregroundStyle(.secondary)
              .font(.callout)
            Text("Requires app restart.")
              .foregroundStyle(.secondary)
              .font(.callout)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          VStack(alignment: .leading) {
            Toggle(
              "Share crash reports with Supacode",
              isOn: $store.crashReportsEnabled
            )
            .help("Share anonymous crash reports with Supacode (requires restart)")
            Text("Anonymous crash reports help improve stability.")
              .foregroundStyle(.secondary)
              .font(.callout)
            Text("Requires app restart.")
              .foregroundStyle(.secondary)
              .font(.callout)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .formStyle(.grouped)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}
