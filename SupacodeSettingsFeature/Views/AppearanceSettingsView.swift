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
        GlobalHotkeySettingRow(store: store)
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

// System-wide show/hide hotkey, sharing the recorder UX with the shortcut table.
private struct GlobalHotkeySettingRow: View {
  @Bindable var store: StoreOf<SettingsFeature>
  @State private var isRecording = false

  var body: some View {
    LabeledContent {
      HStack(spacing: 6) {
        if let hotkey = store.globalToggleVisibilityHotkey {
          Button {
            isRecording = true
          } label: {
            Text(hotkey.displayString)
              .foregroundStyle(.primary)
          }
          .buttonStyle(.plain)
          .help("Change the shortcut.")
          Button {
            store.send(.setGlobalToggleHotkey(nil))
          } label: {
            Image(systemName: "xmark")
              .imageScale(.small)
              .fontWeight(.semibold)
              .padding(2)
              .accessibilityLabel("Remove shortcut")
          }
          .buttonStyle(.bordered)
          .buttonBorderShape(.circle)
          .controlSize(.small)
          // Inset so the circle aligns with the disclosure controls in the rows below.
          .padding(.trailing, 3.5)
          .help("Remove the shortcut.")
        } else {
          Button("Record") {
            isRecording = true
          }
          .help("Record a system-wide hotkey to toggle Supacode.")
        }
      }
      .popover(isPresented: $isRecording) {
        HotkeyRecorderPopover(
          onRecorded: { store.send(.setGlobalToggleHotkey($0)) },
          onCancelled: { isRecording = false },
          conflictChecker: conflictName(for:)
        )
      }
      .contextMenu {
        Button("Record Shortcut…") { isRecording = true }
        if store.globalToggleVisibilityHotkey != nil {
          Divider()
          Button("Remove Shortcut") { store.send(.setGlobalToggleHotkey(nil)) }
        }
      }
    } label: {
      Text("Global hotkey")
      if store.globalHotkeyRegistrationFailed {
        Text("That hotkey is unavailable. Another app may already use it.")
          .foregroundStyle(.red)
      } else {
        Text("Toggle Supacode from anywhere.")
      }
    }
  }

  // A global chord captured system-wide would also shadow a matching in-app
  // shortcut, so reject both system-reserved chords and effective app shortcuts.
  private func conflictName(for override: AppShortcutOverride) -> String? {
    let display = override.displayString
    if AppShortcutOverride.allReservedDisplayStrings().contains(display) { return "the system" }
    for shortcut in AppShortcuts.all {
      guard let effective = shortcut.effective(from: store.shortcutOverrides) else { continue }
      if effective.display == display { return shortcut.displayName }
    }
    return nil
  }
}
