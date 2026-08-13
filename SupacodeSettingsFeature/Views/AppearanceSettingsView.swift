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
        LabeledContent {
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
          // Keeps the wrapping subtitle from hugging the option cards.
          .padding(.leading, 16)
        } label: {
          Text("Appearance")
          Text("Follow the system appearance, or always use light or dark.")
        }
      }
      Section {
        LabeledContent {
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
          // Keeps the wrapping subtitle from hugging the option cards.
          .padding(.leading, 16)
        } label: {
          Text("Visibility")
          Text("Show Supacode in the Dock, the menu bar, or both.")
        }
      }
      Section {
        Picker(selection: $store.confirmCloseTab) {
          ForEach(ConfirmCloseTabMode.allCases, id: \.self) { mode in
            DefaultTaggedLabel(label: mode.label, isDefault: mode == GlobalSettings.default.confirmCloseTab)
              .tag(mode)
          }
        } label: {
          Text("Confirm before closing tabs")
          Text(store.confirmCloseTab.subtitle)
        }
        Picker(selection: $store.confirmQuitMode) {
          ForEach(ConfirmQuitMode.allCases, id: \.self) { mode in
            DefaultTaggedLabel(label: mode.label, isDefault: mode == GlobalSettings.default.confirmQuitMode)
              .tag(mode)
          }
        } label: {
          Text("Confirm before quitting app")
          Text(store.confirmQuitMode.subtitle)
        }
      }
      Section("Editor & Layout") {
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
          DefaultTaggedLabel(label: "Auto", isDefault: true)
            .tag(OpenWorktreeAction.automaticSettingsID)
          ForEach(openActionOptions) { action in
            Text(action.labelTitle)
              .tag(action.settingsID)
          }
        } label: {
          Text("Global editor")
          Text("Applies to Worktrees without repository overrides.")
        }
        Picker(selection: $store.hoverFocusMode) {
          ForEach(HoverFocusMode.allCases, id: \.self) { mode in
            DefaultTaggedLabel(label: mode.label, isDefault: mode == .never).tag(mode)
          }
        } label: {
          Text("Focus panes on hover")
          Text("Move focus to a split pane as the pointer moves over it, within the active window.")
        }
      }
      Section("Accessibility") {
        Picker(selection: $store.chromeTextSize) {
          ForEach(ChromeTextSize.allCases) { size in
            DefaultTaggedLabel(label: size.label, isDefault: size == .default).tag(size)
          }
        } label: {
          HStack(spacing: 6) {
            Text("Text size")
            BetaBadge()
          }
          Text("Sizes all non-terminal text. The terminal keeps its own font size.")
        }
      }
      Section {
        Toggle(isOn: $store.analyticsEnabled) {
          Text("Share analytics")
          Text("Anonymous usage data helps improve Supacode.")
        }
        Toggle(isOn: $store.crashReportsEnabled) {
          Text("Share crash reports")
          Text("Anonymous crash reports help improve stability.")
        }
      } header: {
        Text("Analytics")
      } footer: {
        Text("Changes to Analytics require Supacode to restart before they take effect.")
      }
    }
    .formStyle(.grouped)
    .contentMargins(.trailing, 6, for: .scrollIndicators)
    .padding(.top, -20)
    .padding(.leading, -8)
    .padding(.trailing, -6)
    .navigationTitle("General")
  }
}
