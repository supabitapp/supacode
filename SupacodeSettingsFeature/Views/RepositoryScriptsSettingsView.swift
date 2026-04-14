import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

/// Settings sub-section for managing on-demand scripts.
public struct RepositoryScriptsSettingsView: View {
  @Bindable var store: StoreOf<RepositorySettingsFeature>

  public init(store: StoreOf<RepositorySettingsFeature>) {
    self.store = store
  }

  public var body: some View {
    Form {
      Section {
        if store.settings.scripts.isEmpty {
          Text("No scripts configured.")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 8)
        } else {
          List {
            ForEach($store.settings.scripts) { $script in
              ScriptRow(script: $script)
            }
            .onDelete { offsets in
              store.send(.removeScripts(offsets))
            }
            .onMove { source, destination in
              store.send(.moveScripts(source, destination))
            }
          }
          .listStyle(.bordered(alternatesRowBackgrounds: true))
          .frame(minHeight: 120)
        }
      } header: {
        Text("Scripts")
        Text("Launched on demand from the toolbar, command palette, or keyboard shortcut.")
      } footer: {
        Text("Drag to reorder. The first script is used as the default.")
      }

      Section("Environment Variables") {
        ScriptEnvironmentRow(
          name: "SUPACODE_WORKTREE_PATH",
          description: "Path to the active worktree."
        )
        ScriptEnvironmentRow(
          name: "SUPACODE_ROOT_PATH",
          description: "Path to the repository root."
        )
      }
    }
    .formStyle(.grouped)
    .padding(.top, -20)
    .padding(.leading, -8)
    .padding(.trailing, -6)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          store.send(.addScript)
        } label: {
          Image(systemName: "plus")
            .accessibilityLabel("Add Script")
        }
        .help("Add a new script.")
      }
    }
  }
}

// MARK: - Script row.

private struct ScriptRow: View {
  @Binding var script: ScriptDefinition

  var body: some View {
    HStack(spacing: 12) {
      Picker(selection: $script.kind) {
        ForEach(ScriptKind.allCases, id: \.self) { kind in
          Label(kind.defaultName, systemImage: kind.defaultSystemImage)
            .tag(kind)
        }
      } label: {
        EmptyView()
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .frame(width: 100)
      .onChange(of: script.kind) { _, newKind in
        script.systemImage = newKind.defaultSystemImage
        script.tintColor = newKind.defaultTintColor
      }
      TextField("Name", text: $script.name)
        .frame(minWidth: 80)
      TextField("Command", text: $script.command)
        .monospaced()
        .frame(minWidth: 120)
    }
    .padding(.vertical, 4)
  }
}

// MARK: - Environment row.

private struct ScriptEnvironmentRow: View {
  let name: String
  let description: String

  var body: some View {
    LabeledContent {
      Button {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(name, forType: .string)
      } label: {
        Image(systemName: "doc.on.doc")
          .accessibilityLabel("Copy variable key")
      }
      .buttonStyle(.borderless)
      .help("Copy variable key.")
    } label: {
      Text(name).monospaced()
      Text(description)
    }
  }
}
