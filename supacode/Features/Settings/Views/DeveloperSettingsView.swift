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
    let uninstalled = store.uninstalledAgents
    Group {
      // Each agent gets its own section so multi-folder rows never blend across agents.
      ForEach(store.mainListAgentRows, id: \.self) { agent in
        Section {
          AgentIntegrationRow(agent: agent, store: store)
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
            .appFont(.subheadline)
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
        // Each agent in its own section, matching the Developer list; the first
        // carries the modal's header.
        ForEach(Array(store.agentInstallSheetAgents.enumerated()), id: \.element) { index, agent in
          Section {
            AgentIntegrationRow(agent: agent, store: store, showsAllFeatures: true)
          } header: {
            index == 0 ? Text("Add Agent Integration") : nil
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

/// One agent: its mark and capability grid once, then a line per install
/// location (the default, plus any custom folders).
private struct AgentIntegrationRow: View {
  let agent: SkillAgent
  let store: StoreOf<SettingsFeature>
  let showsAllFeatures: Bool

  init(agent: SkillAgent, store: StoreOf<SettingsFeature>, showsAllFeatures: Bool = false) {
    self.agent = agent
    self.store = store
    self.showsAllFeatures = showsAllFeatures
  }

  private var capabilities: [FeatureCapability] {
    AgentFeature.allCases.map { FeatureCapability(name: $0.title, isSupported: agent.supports($0)) }
  }

  var body: some View {
    let defaultPresent = (store.agentIntegrationStates[agent] ?? .checking).isPresentOnDisk
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Image(agent.assetName)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: 18, height: 18)
        .foregroundStyle(.primary)
        // Image has no native baseline; nudge so its visual center sits near the title baseline.
        .alignmentGuide(.firstTextBaseline) { dimension in dimension[.bottom] - 5 }
        .accessibilityHidden(true)
      // Outer spacing gives dividers even breathing room; the title and grid stay tightly grouped.
      VStack(alignment: .leading, spacing: 6) {
        VStack(alignment: .leading, spacing: 2) {
          HStack(alignment: .firstTextBaseline) {
            Text(agent.displayName)
            Spacer()
            // Once the default is installed the split button is gone, so this is
            // the affordance for adding another folder.
            if agent.supportsCustomConfigFolder && defaultPresent {
              Button("Install at Folder\u{2026}") { store.send(.agentAddCustomFolderTapped(agent)) }
                .help("Install the \(agent.displayName) integration into another folder.")
            }
          }
          FeatureCapabilityGrid(capabilities: capabilities, supportedOnly: !showsAllFeatures)
        }
        // One line per install location, each set off by a row separator.
        ForEach(targets, id: \.self) { target in
          Divider()
          AgentInstallTargetLine(
            agent: agent,
            target: target,
            state: store.agentIntegrationStates[target] ?? .checking,
            directoryExists: store.configDirectoriesOnDisk.contains(target),
            install: { store.send(.agentIntegrationInstallTapped(target)) },
            uninstall: { store.send(.agentIntegrationUninstallTapped(target)) },
            addCustomFolder: { store.send(.agentAddCustomFolderTapped(agent)) }
          )
        }
      }
    }
  }

  /// The default location first, then any custom folders in state for this agent.
  private var targets: [AgentInstallTarget] {
    let customs = store.agentIntegrationStates.keys
      .filter { $0.agent == agent && $0.location != .standard }
      .sorted { ($0.configDirectoryURL?.path ?? "") < ($1.configDirectoryURL?.path ?? "") }
    return [.standard(agent)] + customs
  }
}

/// One install location under an agent: the config path phrased for the state,
/// and that location's own install control.
private struct AgentInstallTargetLine: View {
  let agent: SkillAgent
  let target: AgentInstallTarget
  let state: AgentIntegrationRowState
  let directoryExists: Bool
  let install: () -> Void
  let uninstall: () -> Void
  let addCustomFolder: () -> Void

  private var isStandard: Bool { target.location == .standard }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
          if let verb = verbPrefix {
            Text(verb)
              .appFont(.subheadline)
              .foregroundStyle(.secondary)
          }
          pathLabel
        }
        if let message = state.errorMessage {
          Text(message)
            .appFont(.subheadline)
            .foregroundStyle(state.isUndetermined ? Color.orange : Color.red)
        }
      }
      Spacer()
      trailingControl
    }
  }

  /// Resolved directory to reveal in Finder.
  private var configDirectoryURL: URL { target.configDirectory() }

  private var configPath: String {
    (configDirectoryURL.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
  }

  /// Leading verb for the state, or `nil` when the line is just the path.
  private var verbPrefix: String? {
    switch state {
    case .installing: "Installing at"
    case .uninstalling: "Removing"
    case .ready(.installed), .ready(.outdated): "Installed at"
    case .undetermined(let lastKnown, _): lastKnown == nil ? nil : "Installed at"
    // A failed row still offers Install (retry), so it reads as prospective.
    case .ready(.notInstalled), .failed, .failedTransient: "Installs to"
    case .checking: nil
    }
  }

  private var showsEllipsis: Bool {
    switch state {
    case .installing, .uninstalling: true
    case .checking, .ready, .failed, .failedTransient, .undetermined: false
    }
  }

  /// The path: a Finder-revealing link (tinted, with an arrow) whenever the
  /// directory is on disk (so even a prospective install links, since the
  /// agent's config dir already exists), otherwise the plain forge-style path.
  @ViewBuilder private var pathLabel: some View {
    if directoryExists && !showsEllipsis {
      Button {
        NSWorkspace.shared.open(configDirectoryURL)
      } label: {
        Text(verbatim: "\(configPath) \u{2197}")
      }
      .buttonStyle(.plain)
      .foregroundStyle(.tint)
      .appFont(.subheadline)
      .help("Show \(configPath) in Finder")
    } else {
      Text(verbatim: showsEllipsis ? "\(configPath)\u{2026}" : configPath)
        .appFont(.subheadline)
        .foregroundStyle(.secondary)
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
        Button("Uninstall", role: .destructive, action: uninstall)
      }
    case .ready(.outdated), .undetermined(.outdated, _):
      ControlGroup {
        Button("Update", action: install)
        Button("Uninstall", role: .destructive, action: uninstall)
      }
    case .ready(.notInstalled), .failed, .failedTransient, .undetermined(.notInstalled, _),
      .undetermined(nil, _):
      installControl
    case .installing:
      Button("Installing\u{2026}") {}.disabled(true)
    case .uninstalling:
      Button("Uninstalling\u{2026}") {}.disabled(true)
    }
  }

  /// Not-installed control. A supporting agent's default offers the split
  /// button (primary installs the default, the menu adds a custom folder). A
  /// custom row offers retry plus remove; everything else a plain Install.
  @ViewBuilder
  private var installControl: some View {
    if isStandard && agent.supportsCustomConfigFolder {
      Menu {
        Button("Install at Folder\u{2026}", action: addCustomFolder)
      } label: {
        Text("Install")
      } primaryAction: {
        install()
      }
      .fixedSize()
      .help("Install into \(configPath), or choose another folder.")
    } else if !isStandard {
      ControlGroup {
        Button("Install", action: install)
        Button("Remove", role: .destructive, action: uninstall)
      }
    } else {
      Button("Install", action: install)
    }
  }
}

extension AgentIntegrationRowState {
  /// True when the last disk read found the integration present (installed or
  /// outdated), so the default's "add another folder" affordance can show.
  fileprivate var isPresentOnDisk: Bool {
    switch self {
    case .ready(.installed), .ready(.outdated), .undetermined(.installed, _), .undetermined(.outdated, _):
      true
    case .checking, .installing, .uninstalling, .failed, .failedTransient, .ready(.notInstalled),
      .undetermined(.notInstalled, _), .undetermined(nil, _):
      false
    }
  }
}

// MARK: - Per-agent capability grid.
