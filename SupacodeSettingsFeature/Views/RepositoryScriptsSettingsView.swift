import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

/// Settings sub-section for managing on-demand and lifecycle scripts.
public struct RepositoryScriptsSettingsView: View {
  @Bindable var store: StoreOf<RepositorySettingsFeature>

  public init(store: StoreOf<RepositorySettingsFeature>) {
    self.store = store
  }

  public var body: some View {
    Form {
      // Lifecycle scripts.
      Section {
        ScriptCommandEditor(text: $store.settings.setupScript, label: "Setup Script")
      } header: {
        Label {
          VStack(alignment: .leading, spacing: 0) {
            Text("Setup Script")
              .font(.body)
              .bold()
              .lineLimit(1)
            Text("Runs once after worktree creation.")
              .font(.footnote)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        } icon: {
          Image(systemName: "truck.box.badge.clock").foregroundStyle(.blue).accessibilityHidden(true)
        }.labelStyle(.verticallyCentered)
      } footer: {
        Text("e.g., `pnpm install`")
      }

      Section {
        ScriptCommandEditor(text: $store.settings.archiveScript, label: "Archive Script")
      } header: {
        Label {
          VStack(alignment: .leading, spacing: 0) {
            Text("Archive Script")
              .font(.body)
              .bold()
              .lineLimit(1)
            Text("Runs before a worktree is archived.")
              .font(.footnote)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        } icon: {
          Image(systemName: "archivebox").foregroundStyle(.orange).accessibilityHidden(true)
        }.labelStyle(.verticallyCentered)
      } footer: {
        Text("e.g., `docker compose down`")
      }

      Section {
        ScriptCommandEditor(text: $store.settings.deleteScript, label: "Delete Script")
      } header: {
        Label {
          VStack(alignment: .leading, spacing: 0) {
            Text("Delete Script")
              .font(.body)
              .bold()
              .lineLimit(1)
            Text("Runs before a worktree is deleted.")
              .font(.footnote)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        } icon: {
          Image(systemName: "trash").foregroundStyle(.red).accessibilityHidden(true)
        }.labelStyle(.verticallyCentered)
      } footer: {
        Text("e.g., `docker compose down`")
      }

      // User-defined scripts, each in its own section.
      ForEach(Array($store.settings.scripts.enumerated()), id: \.element.id) { index, $script in
        Section {
          if script.kind == .custom {
            TextField("Name", text: $script.name)
          }
          ScriptCommandEditor(text: $script.command, label: script.displayName)
          Button("Remove Script", role: .destructive) {
            store.send(.removeScripts(IndexSet(integer: index)))
          }
          .help("Remove this script.")
        } header: {
          Label {
            Text("\(script.name) Script")
              .font(.body)
              .bold()
          } icon: {
            Image(systemName: script.resolvedSystemImage).foregroundStyle(script.resolvedTintColor.color)
              .accessibilityHidden(true)
          }.labelStyle(.verticallyCentered)
        }
      }

    }
    .formStyle(.grouped)
    .padding(.top, -20)
    .padding(.leading, -8)
    .padding(.trailing, -6)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        let usedKinds = Set(store.settings.scripts.map(\.kind))
        Menu {
          ForEach(ScriptKind.allCases, id: \.self) { kind in
            if kind == .custom || !usedKinds.contains(kind) {
              Button {
                store.send(.addScript(kind))
              } label: {
                Label {
                  Text("\(kind.defaultName) Script")
                } icon: {
                  Image.tintedSymbol(kind.defaultSystemImage, color: kind.defaultTintColor.nsColor)
                }
              }
            }
          }
        } label: {
          Image(systemName: "plus")
            .accessibilityLabel("Add Script")
        }
        .help("Add a new script.")
      }
    }
  }
}

/// Monospaced text editor for script commands.
private struct ScriptCommandEditor: View {
  @Binding var text: String
  let label: String

  var body: some View {
    TextEditor(text: $text)
      .monospaced()
      .textEditorStyle(.plain)
      .autocorrectionDisabled()
      .frame(height: 90)
      .accessibilityLabel(label)
  }
}
