import ComposableArchitecture
import SwiftUI

struct CodingAgentsSettingsView: View {
  let store: StoreOf<SettingsFeature>

  var body: some View {
    Form {
      Section(
        footer: Text("Hooks are optional and designed to extend Supacode without affecting core functionality.")
      ) {}
      Section {
        AgentInstallRow(
          installAction: { store.send(.agentHookInstallTapped(.claudeProgress)) },
          uninstallAction: { store.send(.agentHookUninstallTapped(.claudeProgress)) },
          installState: store.claudeProgressState,
          title: "Progress",
          subtitle: "Display agent activity in tab and sidebar."
        )
        AgentInstallRow(
          installAction: { store.send(.agentHookInstallTapped(.claudeNotifications)) },
          uninstallAction: { store.send(.agentHookUninstallTapped(.claudeNotifications)) },
          installState: store.claudeNotificationsState,
          title: "Notifications",
          subtitle: "Forward richer notifications to Supacode."
        )
      } header: {
        Label("Claude Code", image: "claude-code-mark")
      } footer: {
        Text("Applied to `~/.claude/settings.json`.")
      }
      Section {
        AgentInstallRow(
          installAction: { store.send(.agentHookInstallTapped(.codexProgress)) },
          uninstallAction: { store.send(.agentHookUninstallTapped(.codexProgress)) },
          installState: store.codexProgressState,
          title: "Progress",
          subtitle: "Display agent activity in tab and sidebar."
        )
        AgentInstallRow(
          installAction: { store.send(.agentHookInstallTapped(.codexNotifications)) },
          uninstallAction: { store.send(.agentHookUninstallTapped(.codexNotifications)) },
          installState: store.codexNotificationsState,
          title: "Notifications",
          subtitle: "Forward richer notifications to Supacode."
        )
      } header: {
        Label("Codex", image: "codex-mark")
      } footer: {
        Text("Applied to `~/.codex/hooks.json`.")
      }
    }
    .formStyle(.grouped)
    .padding(.top, -20)
    .padding(.leading, -8)
    .padding(.trailing, -6)
    .navigationTitle("Coding Agents")
  }
}

private struct AgentInstallRow: View {
  let installAction: () -> Void
  let uninstallAction: () -> Void
  let installState: AgentHooksInstallState
  let title: String
  let subtitle: String

  var body: some View {
    LabeledContent {
      switch installState {
      case .checking:
        ProgressView()
      case .installed:
        ControlGroup {
          Label("Installed", systemImage: "checkmark")
          Button("Uninstall", role: .destructive, action: uninstallAction)
        }
      case .notInstalled, .failed:
        Button("Install", action: installAction)
      case .installing:
        Button("Installing\u{2026}") {}
          .disabled(true)
      case .uninstalling:
        Button("Uninstalling\u{2026}") {}
          .disabled(true)
      }
    } label: {
      Text(title)
      Text(subtitle)
      if let message = installState.errorMessage {
        Text(message).foregroundStyle(.red)
      }
    }
  }
}
