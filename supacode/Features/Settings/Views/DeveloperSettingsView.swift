import ComposableArchitecture
import SupacodeSettingsFeature
import SupacodeSettingsShared
import SwiftUI

struct DeveloperSettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>

  var body: some View {
    Form {
      Section {
        DeeplinkRow()
        CLIInstallRow(store: store)
      } footer: {
        Text("Symlinks `supacode` to `/usr/local/bin`. This is not required to run `supacode` in the app terminals.")
      }
      Section {
        Toggle(isOn: $store.richAgentNotificationsEnabled) {
          Text("Rich notifications")
          Text("Stop and notification hooks deliver the agent's last message instead of a generic alert.")
        }
        Toggle(isOn: $store.agentPresenceBadgesEnabled) {
          Text("Agent badges")
          Text("Show an icon in the sidebar and tab while a coding agent is running in that surface.")
        }
      } header: {
        Text("Coding Agents")
      } footer: {
        Text("These features require the per-agent enhancements installed below.")
      }
      Section {
        ForEach(SkillAgent.allCases, id: \.self) { agent in
          AgentIntegrationRow(
            agent: agent,
            state: store.agentIntegrationStates[agent] ?? .checking,
            installAction: { store.send(.agentIntegrationInstallTapped(agent)) },
            uninstallAction: { store.send(.agentIntegrationUninstallTapped(agent)) }
          )
        }
      }
      Section {
        Toggle(isOn: $store.autoUpdateAgentIntegrationsEnabled) {
          Text("Automatically update agent integrations")
          Text(
            "Re-installs hooks for any agent reporting an outdated integration when Supacode comes to the foreground.")
        }
        .help("Silently re-applies the canonical hook layout to outdated agent integrations when Supacode activates.")
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

// MARK: - Agent integration row.

private struct AgentIntegrationRow: View {
  let agent: SkillAgent
  let state: AgentIntegrationRowState
  let installAction: () -> Void
  let uninstallAction: () -> Void

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Image(agent.assetName)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: 18, height: 18)
        .foregroundStyle(.primary)
        // Image has no native baseline; nudge so its visual center sits near the title baseline.
        .alignmentGuide(.firstTextBaseline) { dimension in dimension[.bottom] - 5 }
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(agent.displayName)
        Text(agent.integrationSubtitle)
          .font(.subheadline)
          .foregroundStyle(.secondary)
        if let message = state.errorMessage {
          Text(message).font(.subheadline).foregroundStyle(.red)
        }
      }
      Spacer()
      trailingControl
    }
  }

  @ViewBuilder
  private var trailingControl: some View {
    switch state {
    case .checking:
      ProgressView()
    case .ready(.installed):
      ControlGroup {
        Label("Installed", systemImage: "checkmark")
        Button("Uninstall", role: .destructive, action: uninstallAction)
      }
    case .ready(.outdated):
      ControlGroup {
        Button("Update", action: installAction)
        Button("Uninstall", role: .destructive, action: uninstallAction)
      }
    case .ready(.notInstalled), .failed:
      Button("Install", action: installAction)
    case .installing:
      Button("Installing\u{2026}") {}
        .disabled(true)
    case .uninstalling:
      Button("Uninstalling\u{2026}") {}
        .disabled(true)
    }
  }
}

// MARK: - Per-agent integration subtitle.

extension SkillAgent {
  fileprivate var integrationSubtitle: LocalizedStringKey {
    switch self {
    case .claude: "Hooks in `~/.claude/settings.json` and skill in `~/.claude/skills/`."
    case .codex:
      """
      Hooks in `~/.codex/hooks.json` and skill in `~/.codex/skills/`. After installing, trust the hooks in Codex; \
      the badge appears once you send the first message.
      """
    case .copilot: "Hooks in `~/.copilot/hooks/supacode.json` and skill in `~/.copilot/skills/`."
    case .hermes: "Plugin in `~/.hermes/plugins/` and skill in `~/.hermes/skills/`."
    case .kimi: "Hooks in `~/.kimi/config.toml` and skill in `~/.kimi/skills/`. Hooks system is in Beta."
    case .kiro: "Hooks in `~/.kiro/agents/` and skill in `~/.kiro/skills/`."
    case .omp: "Extension in `~/.omp/agent/extensions/` and skill in `~/.omp/agent/skills/`."
    case .opencode: "Plugin in `~/.config/opencode/plugins/` and skill in `~/.config/opencode/skills/`."
    case .pi: "Extension in `~/.pi/agent/extensions/` and skill in `~/.pi/agent/skills/`."
    }
  }
}
