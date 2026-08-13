import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

/// Settings sub-section for managing scripts shared across every repository.
public struct GlobalScriptsSettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>

  public init(store: StoreOf<SettingsFeature>) {
    self.store = store
  }

  public var body: some View {
    ScrollViewReader { proxy in
      Form {
        // A hook, not a menu script, so it sits outside the global-scripts list and shows even
        // when there are none. A repo's own script wins; empty here uses the system default app.
        LifecycleScriptSection(
          text: $store.openFileScript,
          title: "Open File Script",
          subtitle: "Fallback for opening a double-clicked file when the repository sets none.",
          icon: "arrow.up.forward.app",
          iconColor: .teal,
          footerExample: "nvim \"$SUPACODE_FILE_PATH\""
        )

        Section(
          footer: Text(
            store.globalScripts.isEmpty
              ? "Add a script to make it available in every repository's toolbar and command palette."
              : "Global scripts are available in every repository's toolbar and command palette."
          )
        ) {}

        ForEach($store.globalScripts) { $script in
          Section {
            TextField("Name", text: $script.name)
            LabeledContent("Color") {
              ColorSwatchRow(color: $script.tintColor)
            }
            ScriptCommandEditor(text: $script.command, label: script.displayName)
            Button("Remove Script…", role: .destructive) {
              store.send(.removeGlobalScript(script.id))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .help("Remove this script.")
          } header: {
            Label {
              Text("\(script.displayName) Script")
                .appFont(.body)
                .bold()
            } icon: {
              Image(systemName: script.resolvedSystemImage)
                .foregroundStyle(script.resolvedTintColor.color)
                .accessibilityHidden(true)
            }
            .labelStyle(.verticallyCentered)
          }
          .id(script.id)
        }
      }
      .formStyle(.grouped)
      .contentMargins(.trailing, 6, for: .scrollIndicators)
      .padding(.top, -20)
      .padding(.leading, -8)
      .padding(.trailing, -6)
      // Scroll the newly appended section into view; otherwise an add gives no
      // visible feedback when the form is already taller than the window.
      .onChange(of: store.globalScripts.count) { oldCount, newCount in
        guard newCount > oldCount, let last = store.globalScripts.last else { return }
        withAnimation { proxy.scrollTo(last.id, anchor: .top) }
      }
    }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          store.send(.addGlobalScript)
        } label: {
          Image(systemName: "plus")
            .accessibilityLabel("Add Global Script")
        }
        .help("Add a new global script.")
      }
    }
    .dismissSystemColorPanelOnDisappear()
  }
}
