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
    Group {
      if store.globalScripts.isEmpty {
        ContentUnavailableView(
          "No Global Scripts",
          systemImage: "terminal",
          description: Text("Add a script to make it available in every repository's toolbar and command palette.")
        )
      } else {
        scriptsForm
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
  }

  private var scriptsForm: some View {
    Form {
      Section(
        footer: Text("Global scripts are available in every repository's toolbar and command palette.")
      ) {}

      ForEach($store.globalScripts) { $script in
        Section {
          TextField("Name", text: $script.name)
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
              .font(.body)
              .bold()
          } icon: {
            Image(systemName: script.resolvedSystemImage)
              .foregroundStyle(script.resolvedTintColor.color)
              .accessibilityHidden(true)
          }
          .labelStyle(.verticallyCentered)
        }
      }
    }
    .formStyle(.grouped)
    .padding(.top, -20)
    .padding(.leading, -8)
    .padding(.trailing, -6)
  }
}
