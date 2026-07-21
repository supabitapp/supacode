import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

public struct AppearanceSettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>

  public init(store: StoreOf<SettingsFeature>) {
    self.store = store
  }

  public var body: some View {
    let openActionOptions = store.installedOpenActions
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
          Text("Supacode Terminal Theme")
          Text("When off, honors your Ghostty config theme.")
        }
      }
      Section {
        Picker(selection: $store.confirmQuitMode) {
          ForEach(ConfirmQuitMode.allCases, id: \.self) { mode in
            Text(mode.label).tag(mode)
          }
        } label: {
          Text("Confirm before Quitting")
          Text(store.confirmQuitMode.subtitle)
        }
        Toggle(isOn: $store.terminateSessionsOnQuit) {
          Text("Terminate Sessions on Quit")
          Text(
            """
            Close all tabs and stop background shells when quitting.
            Terminal persistence is powered by [zmx \u{2197}](https://github.com/neurosnap/zmx).
            """
          )
        }
        Toggle(isOn: $store.remoteSessionPersistenceEnabled) {
          Text("Persist Remote Sessions on Host")
          Text(
            """
            Keeps SSH surfaces alive across disconnects when \
            [zmx \u{2197}](https://github.com/neurosnap/zmx) is installed on the host.
            """
          )
        }
      }
      Section {
        LabeledContent("Visibility") {
          HStack(spacing: 12) {
            ForEach(AppVisibility.allCases) { visibility in
              AppVisibilityOptionCardView(
                visibility: visibility,
                isSelected: visibility == store.appVisibility
              ) {
                store.send(.setAppVisibility(visibility))
              }
            }
          }
        }
      }
      Section("Editor") {
        // The stored id deliberately keeps naming an uninstalled editor, so the choice
        // survives a reinstall. No row is tagged with it though, and an untagged
        // selection renders blank, so normalize for display and write back raw.
        let storedEditorID = $store.defaultEditorID
        let defaultEditorID = Binding(
          get: {
            OpenWorktreeAction.normalizedDefaultEditorID(
              storedEditorID.wrappedValue,
              installed: openActionOptions
            )
          },
          set: { storedEditorID.wrappedValue = $0 }
        )
        Picker(
          selection: defaultEditorID
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
        Toggle(isOn: $store.confirmCloseSurface) {
          Text("Confirm before Closing Terminals")
          Text("Ask before closing a terminal that has a running process.")
        }
        Picker(selection: $store.automatedActionPolicy.sending(\.setAutomatedActionPolicy)) {
          ForEach(AutomatedActionPolicy.allCases, id: \.self) { policy in
            Text(policy.displayName).tag(policy)
          }
        } label: {
          Text("Allow Arbitrary Actions")
          Text("Skip the confirmation dialog for commands and destructive actions.")
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
