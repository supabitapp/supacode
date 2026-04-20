import ComposableArchitecture
import SupacodeSettingsFeature
import SupacodeSettingsShared
import SwiftUI

struct DeveloperSettingsView: View {
  let store: StoreOf<SettingsFeature>
  @State private var kiroExpanded = false
  @State private var piExpanded = false

  var body: some View {
    Form {
      Section(
        footer: Text("CLI, hooks, and skills are optional and extend Supacode without affecting core functionality.")
      ) {}
      Section {
        DeeplinkRow()
        CLIInstallRow(store: store)
      } footer: {
        Text("Symlinks `supacode` to `/usr/local/bin`. This is not required to run `supacode` in the app terminals.")
      }
      Section {
        AgentInstallRow(
          installAction: { store.send(.agentHookInstallTapped(.claudeProgress)) },
          uninstallAction: { store.send(.agentHookUninstallTapped(.claudeProgress)) },
          installState: store.claudeProgressState,
          title: "Progress Hook",
          subtitle: "Display agent activity in tab and sidebar."
        )
        AgentInstallRow(
          installAction: { store.send(.agentHookInstallTapped(.claudeNotifications)) },
          uninstallAction: { store.send(.agentHookUninstallTapped(.claudeNotifications)) },
          installState: store.claudeNotificationsState,
          title: "Notifications Hook",
          subtitle: "Forward richer notifications to Supacode."
        )
        AgentInstallRow(
          installAction: { store.send(.cliSkillInstallTapped(.claude)) },
          uninstallAction: { store.send(.cliSkillUninstallTapped(.claude)) },
          installState: store.claudeSkillState,
          title: "CLI Skill",
          subtitle: "Teach Claude Code how to use the Supacode CLI."
        )
      } header: {
        Label {
          Text("Claude Code")
        } icon: {
          Image("claude-code-mark")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)
        }
        .labelStyle(.titleTrailingIcon)
      } footer: {
        Text("Applied to `~/.claude`.")
      }
      Section {
        AgentInstallRow(
          installAction: { store.send(.agentHookInstallTapped(.codexProgress)) },
          uninstallAction: { store.send(.agentHookUninstallTapped(.codexProgress)) },
          installState: store.codexProgressState,
          title: "Progress Hook",
          subtitle: "Display agent activity in tab and sidebar."
        )
        AgentInstallRow(
          installAction: { store.send(.agentHookInstallTapped(.codexNotifications)) },
          uninstallAction: { store.send(.agentHookUninstallTapped(.codexNotifications)) },
          installState: store.codexNotificationsState,
          title: "Notifications Hook",
          subtitle: "Forward richer notifications to Supacode."
        )
        AgentInstallRow(
          installAction: { store.send(.cliSkillInstallTapped(.codex)) },
          uninstallAction: { store.send(.cliSkillUninstallTapped(.codex)) },
          installState: store.codexSkillState,
          title: "CLI Skill",
          subtitle: "Teach Codex how to use the Supacode CLI."
        )
      } header: {
        Label {
          Text("Codex")
        } icon: {
          Image("codex-mark")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)
        }
        .labelStyle(.titleTrailingIcon)
      } footer: {
        Text("Applied to `~/.codex`.")
      }
      Section(isExpanded: $kiroExpanded) {
        AgentInstallRow(
          installAction: { store.send(.agentHookInstallTapped(.kiroProgress)) },
          uninstallAction: { store.send(.agentHookUninstallTapped(.kiroProgress)) },
          installState: store.kiroProgressState,
          title: "Progress Hook",
          subtitle: "Display agent activity in tab and sidebar."
        )
        AgentInstallRow(
          installAction: { store.send(.agentHookInstallTapped(.kiroNotifications)) },
          uninstallAction: { store.send(.agentHookUninstallTapped(.kiroNotifications)) },
          installState: store.kiroNotificationsState,
          title: "Notifications Hook",
          subtitle: "Forward richer notifications to Supacode."
        )
        AgentInstallRow(
          installAction: { store.send(.cliSkillInstallTapped(.kiro)) },
          uninstallAction: { store.send(.cliSkillUninstallTapped(.kiro)) },
          installState: store.kiroSkillState,
          title: "CLI Skill",
          subtitle: "Teach Kiro how to use the Supacode CLI."
        )
      } header: {
        Label {
          Text("Kiro")
        } icon: {
          Image("kiro-mark")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)
        }
        .labelStyle(.titleTrailingIcon)
      }
      Section(isExpanded: $piExpanded) {
        AgentInstallRow(
          installAction: { store.send(.agentHookInstallTapped(.piHooks)) },
          uninstallAction: { store.send(.agentHookUninstallTapped(.piHooks)) },
          installState: store.piHooksState,
          title: "Hooks",
          subtitle: "Display agent activity in tab, sidebar, and forward notifications."
        )
        AgentInstallRow(
          installAction: { store.send(.cliSkillInstallTapped(.pi)) },
          uninstallAction: { store.send(.cliSkillUninstallTapped(.pi)) },
          installState: store.piSkillState,
          title: "CLI Skill",
          subtitle: "Teach Pi how to use the Supacode CLI."
        )
      } header: {
        Label {
          Text("Pi")
        } icon: {
          Image("pi-mark")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)
        }
        .labelStyle(.titleTrailingIcon)
      }
    }
    .formStyle(.grouped)
    .padding(.top, -20)
    .padding(.leading, -8)
    .padding(.trailing, -6)
    .navigationTitle("Developer")
  }
}

// MARK: - CLI install + Deeplink rows.

private struct DeeplinkRow: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    LabeledContent {
    } label: {
      Text("Deeplinks")
      Text("Deeplink Reference \u{2197}")
        .foregroundStyle(.tint)
        .contentShape(.rect)
        .accessibilityAddTraits(.isButton)
        .onTapGesture { openWindow(id: WindowID.deeplinkReference) }
    }
  }
}

private struct CLIInstallRow: View {
  @Environment(\.openWindow) private var openWindow
  let store: StoreOf<SettingsFeature>

  var body: some View {
    LabeledContent {
      switch store.cliInstallState {
      case .checking:
        ProgressView()
      case .installed:
        ControlGroup {
          Label("Installed", systemImage: "checkmark")
          Button("Uninstall", role: .destructive) { store.send(.cliUninstallTapped) }
        }
      case .notInstalled, .failed:
        Button("Install") { store.send(.cliInstallTapped) }
      case .installing:
        Button("Installing\u{2026}") {}
          .disabled(true)
      case .uninstalling:
        Button("Uninstalling\u{2026}") {}
          .disabled(true)
      }
    } label: {
      Text("Command Line Tool")
      Text("CLI Reference \u{2197}")
        .foregroundStyle(.tint)
        .contentShape(.rect)
        .accessibilityAddTraits(.isButton)
        .onTapGesture { openWindow(id: WindowID.cliReference) }
      if let message = store.cliInstallState.errorMessage {
        Text(message).foregroundStyle(.red)
      }
    }
  }
}

// MARK: - Agent install row.

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

// MARK: - Title trailing icon label style.

private struct TitleTrailingIconLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack {
      configuration.title
      configuration.icon
    }
  }
}

extension LabelStyle where Self == TitleTrailingIconLabelStyle {
  static var titleTrailingIcon: TitleTrailingIconLabelStyle { .init() }
}
