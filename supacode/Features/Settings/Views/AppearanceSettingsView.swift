import ComposableArchitecture
import SwiftUI

struct AppearanceSettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>

  var body: some View {
    let openActionOptions = OpenWorktreeAction.availableCases
    Form {
      Section {
        LabeledContent("Appearance") {
          HStack(spacing: 12) {
            let appearanceMode = $store.appearanceMode
            ForEach(AppearanceMode.allCases) { mode in
              AppearanceOptionCardView(
                mode: mode,
                isSelected: mode == appearanceMode.wrappedValue
              ) {
                appearanceMode.wrappedValue = mode
              }
            }
          }
        }
        Toggle(isOn: $store.terminalThemeSyncEnabled) {
          Text("Sync with Terminal")
          Text("Applies the appearance-aware Supacode color palette.")
        }
        if !store.terminalThemeSyncEnabled {
          VStack(alignment: .leading, spacing: 4) {
            Text("Add a theme to `~/.config/ghostty/config`")
            Text("e.g. `theme = light:Monokai Pro Light Sun,dark:Dimmed Monokai`")
          }
          .font(.footnote)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
        }
      }
      Section {
        Toggle(
          "Confirm before Quitting",
          isOn: $store.confirmBeforeQuit
        )
        .help("Ask before quitting Supacode")
        Toggle(isOn: $store.restoreTerminalLayoutEnabled) {
          Text("Restore Terminal Layout")
          Text("Reopen tabs, splits, and working directories from your last session.")
        }
        .help("Restore tabs and splits when reopening a worktree")
      }
      Section("Editor") {
        Picker(
          selection: $store.defaultEditorID
        ) {
          Text("Automatic")
            .tag(OpenWorktreeAction.automaticSettingsID)
          ForEach(openActionOptions) { action in
            Text(action.labelTitle)
              .tag(action.settingsID)
          }
        } label: {
          Text("Default Editor")
          Text("Applies to Worktrees without repository overrides.")
        }
      }
      Section {
        Toggle(isOn: $store.analyticsEnabled) {
          Text("Share Analytics")
          Text("Anonymous usage data helps improve Supacode.")
        }
        Toggle(isOn: $store.crashReportsEnabled) {
          Text("Share Crash Reports")
          Text("Anonymous crash reports help improve stability.")
        }
      } header: {
        Text("Analytics")
      } footer: {
        Text("Changes to Analytics require Supacode to restart before they take effect.")
      }
      Section("Advanced") {
        Toggle(isOn: $store.hideSingleTabBar) {
          Text("Hide Tab Bar for Single Tab")
          Text("Automatically hides the tab bar when only one tab is open.")
        }
        Toggle(isOn: $store.allowArbitraryDeeplinkInput) {
          Text("Allow Arbitrary Deeplink Actions")
          Text("Skip the confirmation dialog when a deeplink runs a command or performs a destructive action.")
        }
      }
    }
    .formStyle(.grouped)
    .padding(.top, -20)
    .padding(.leading, -8)
    .padding(.trailing, -6)

    .navigationTitle("General")
  }
}
