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
      // Setup + Archive scripts are git-only — worktree creation
      // and worktree archival are the triggers and folders have
      // neither. The Delete script stays: it runs before the folder
      // itself is removed from Supacode through the blocking-script
      // pipeline.
      if store.isGitRepository {
        LifecycleScriptSection(
          text: $store.settings.setupScript,
          title: "Setup Script",
          subtitle: "Runs once after worktree creation.",
          icon: "truck.box.badge.clock",
          iconColor: .blue,
          footerExample: "pnpm install"
        )
        LifecycleScriptSection(
          text: $store.settings.archiveScript,
          title: "Archive Script",
          subtitle: "Runs before a worktree is archived.",
          icon: "archivebox",
          iconColor: .orange,
          footerExample: "docker compose down"
        )
      }
      LifecycleScriptSection(
        text: $store.settings.deleteScript,
        title: "Delete Script",
        subtitle: store.isGitRepository
          ? "Runs before a worktree is deleted."
          : "Runs before this folder is removed from Supacode.",
        icon: "trash",
        iconColor: .red,
        footerExample: "docker compose down"
      )

      // User-defined scripts, each in its own section.
      ForEach($store.settings.scripts) { $script in
        Section {
          if script.kind == .custom {
            TextField("Name", text: $script.name)
          }
          ScriptCommandEditor(text: $script.command, label: script.displayName)
          Button("Remove Script…", role: .destructive) {
            store.send(.removeScript(script.id))
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
            Image(systemName: script.resolvedSystemImage).foregroundStyle(script.resolvedTintColor.color)
              .accessibilityHidden(true)
          }.labelStyle(.verticallyCentered)
        }
      }

    }
    .alert($store.scope(state: \.alert, action: \.alert))
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

/// Reusable section for lifecycle scripts (setup, archive, delete).
private struct LifecycleScriptSection: View {
  @Binding var text: String
  let title: String
  let subtitle: String
  let icon: String
  let iconColor: Color
  let footerExample: String

  var body: some View {
    Section {
      ScriptCommandEditor(text: $text, label: title)
    } header: {
      Label {
        VStack(alignment: .leading, spacing: 0) {
          Text(title)
            .font(.body)
            .bold()
            .lineLimit(1)
          Text(subtitle)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      } icon: {
        Image(systemName: icon).foregroundStyle(iconColor).accessibilityHidden(true)
      }.labelStyle(.verticallyCentered)
    } footer: {
      Text("e.g., `\(footerExample)`")
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
