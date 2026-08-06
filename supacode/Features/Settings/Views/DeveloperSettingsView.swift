import ComposableArchitecture
import SupacodeSettingsFeature
import SupacodeSettingsShared
import SwiftUI

struct DeveloperSettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>

  var body: some View {
    Form {
      Section {
        CLIInstallRow(store: store)
        DeeplinkRow()
      } footer: {
        Text(
          """
          Installing the CLI symlinks `supacode` to `/usr/local/bin`. \
          This is not required to run `supacode` in the app terminals.
          """
        )
      }
      CodingAgentsSections(store: store)
      Section {
        Toggle(isOn: $store.richAgentNotificationsEnabled) {
          Text("Rich notifications")
          Text("Stop and notification hooks deliver the agent's last message instead of a generic alert.")
        }
        Toggle(isOn: $store.agentPresenceBadgesEnabled) {
          Text("Agent badges")
          Text("Show an icon in the sidebar and tab while a coding agent is running in that surface.")
        }
      } footer: {
        Text("These features require an installed agent integration.")
      }
      Section("Advanced") {
        Picker(selection: $store.automatedActionPolicy.sending(\.setAutomatedActionPolicy)) {
          ForEach(AutomatedActionPolicy.allCases, id: \.self) { policy in
            Text(policy.displayName).tag(policy)
          }
        } label: {
          Text("Allow dangerous actions")
          Text(
            "Skips the confirmation dialog when running commands or scripts, closing tabs or splits, "
              + "and archiving or deleting worktrees.")
        }
      }
    }
    .formStyle(.grouped)
    .contentMargins(.trailing, 6, for: .scrollIndicators)
    .padding(.top, -20)
    .padding(.leading, -8)
    .padding(.trailing, -6)
    .navigationTitle("Developer")
    .sheet(isPresented: $store.agentInstallSheetPresented.sending(\.setAgentInstallSheetPresented)) {
      AgentInstallSheetView(store: store)
    }
  }
}

// MARK: - Coding agents sections.

/// Not-installed agents collapse into one prompt row; the rest render as rows.
private struct CodingAgentsSections: View {
  let store: StoreOf<SettingsFeature>

  var body: some View {
    let mainRows = store.mainListAgentRows
    let uninstalled = store.uninstalledAgents
    Group {
      if !mainRows.isEmpty {
        Section {
          ForEach(mainRows, id: \.self) { agent in
            AgentIntegrationRow(
              agent: agent,
              state: store.agentIntegrationStates[agent] ?? .checking,
              installAction: { store.send(.agentIntegrationInstallTapped(agent)) },
              uninstallAction: { store.send(.agentIntegrationUninstallTapped(agent)) }
            )
          }
        }
      }
      if !uninstalled.isEmpty {
        Section {
          AgentInstallPromptRow(agents: uninstalled) { store.send(.agentInstallSheetOpenTapped) }
        }
      }
    }
  }
}

/// Single collapsed row standing in for every not-yet-installed agent: their
/// avatar lineup, a count, and a button that opens the install modal.
private struct AgentInstallPromptRow: View {
  let agents: [SkillAgent]
  let installAction: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 6) {
        AgentAvatarGroupView(agents: agents, size: 22, maxVisible: .max)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text("Agent integrations")
          Text(subtitle)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }
      Spacer()
      Button("Install\u{2026}", action: installAction)
    }
  }

  private var subtitle: String {
    agents.count == 1 ? "1 available." : "\(agents.count) available."
  }
}

// MARK: - Install modal.

/// Modal listing every not-yet-installed agent (plus mid-install, transiently
/// errored, or outdated ones so rows don't flicker out). Driven entirely by
/// `SettingsFeature` state; the reducer auto-dismisses it once the last agent
/// settles.
private struct AgentInstallSheetView: View {
  let store: StoreOf<SettingsFeature>

  var body: some View {
    NavigationStack {
      Form {
        Section("Add Agent Integration") {
          ForEach(store.agentInstallSheetAgents, id: \.self) { agent in
            AgentIntegrationRow(
              agent: agent,
              state: store.agentIntegrationStates[agent] ?? .checking,
              installAction: { store.send(.agentIntegrationInstallTapped(agent)) },
              uninstallAction: { store.send(.agentIntegrationUninstallTapped(agent)) }
            )
          }
        }
      }
      .formStyle(.grouped)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { store.send(.setAgentInstallSheetPresented(false)) }
        }
      }
    }
    .frame(minWidth: 460, minHeight: 380)
  }
}

// MARK: - CLI install + Deeplink rows.

private struct DeeplinkRow: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    LabeledContent {
    } label: {
      Text("Deeplinks")
      HStack(spacing: 6) {
        ReferenceLink(title: "Deeplink Reference", help: "Open the deeplink reference window.") {
          openWindow(id: WindowID.deeplinkReference)
        }
        if let url = CLISkillContent.deeplinksSkillFileURL {
          Divider()
          ReferenceLink(title: "Skill", help: "Open the bundled supacode-deeplinks skill file.") {
            NSWorkspace.shared.open(url)
          }
        }
      }
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
      HStack(spacing: 6) {
        ReferenceLink(title: "CLI Reference", help: "Open the CLI reference window.") {
          openWindow(id: WindowID.cliReference)
        }
        if let url = CLISkillContent.cliSkillFileURL {
          Divider()
          ReferenceLink(title: "Skill", help: "Open the bundled supacode-cli skill file.") {
            NSWorkspace.shared.open(url)
          }
        }
      }
      if let message = store.cliInstallState.errorMessage {
        Text(message).foregroundStyle(.red)
      }
    }
  }
}

// MARK: - Reference links.

private struct ReferenceLink: View {
  let title: String
  let help: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text("\(title) \u{2197}")
        .foregroundStyle(.tint)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .help(help)
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
          // Must stay a plain `String`: the message embeds a filesystem path that
          // `LocalizedStringKey` would parse as markdown and mangle.
          Text(message)
            .font(.subheadline)
            .foregroundStyle(state.isUndetermined ? Color.orange : Color.red)
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
    case .ready(.installed), .undetermined(.installed, _):
      ControlGroup {
        Label("Installed", systemImage: "checkmark")
        Button("Uninstall", role: .destructive, action: uninstallAction)
      }
    case .ready(.outdated), .undetermined(.outdated, _):
      ControlGroup {
        Button("Update", action: installAction)
        Button("Uninstall", role: .destructive, action: uninstallAction)
      }
    case .ready(.notInstalled), .failed, .failedTransient, .undetermined(.notInstalled, _),
      .undetermined(nil, _):
      // Nothing was read for this agent, but offering Install still beats a row
      // with no action: the attempt surfaces the real error where the warning
      // line only describes it.
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
    case .antigravity:
      """
      Hooks in `~/.gemini/config/hooks.json` & `~/.gemini/antigravity-cli/settings.json` \
      and skill in `~/.gemini/antigravity-cli/skills/`.
      """
    case .claude: "Hooks in `~/.claude/settings.json` and skill in `~/.claude/skills/`."
    case .codex:
      """
      Hooks in `~/.codex/hooks.json` and skill in `~/.codex/skills/`. After installing, trust the hooks in Codex; \
      the badge appears once you send the first message.
      """
    case .copilot: "Hooks in `~/.copilot/hooks/supacode.json` and skill in `~/.copilot/skills/`."
    case .grok: "Hooks in `~/.grok/hooks/supacode.json` and skill in `~/.grok/skills/`."
    case .hermes: "Plugin in `~/.hermes/plugins/` and skill in `~/.hermes/skills/`."
    case .kimi: "Hooks in `~/.kimi-code/config.toml` and skill in `~/.kimi-code/skills/`. Hooks system is in Beta."
    case .kiro: "Hooks in `~/.kiro/agents/` and skill in `~/.kiro/skills/`."
    case .omp: "Extension in `~/.omp/agent/extensions/` and skill in `~/.omp/agent/skills/`."
    case .opencode: "Plugin in `~/.config/opencode/plugins/` and skill in `~/.config/opencode/skills/`."
    case .pi: "Extension in `~/.pi/agent/extensions/` and skill in `~/.pi/agent/skills/`."
    }
  }
}
