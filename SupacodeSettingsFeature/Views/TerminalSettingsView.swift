import AppKit
import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

/// The optional user-authored Ghostty config Supacode layers on top of (or in
/// place of) the standard Ghostty config.
enum GhosttyUserConfigFile {
  static var url: URL { SupacodePaths.ghosttyUserConfigURL }

  /// Mirrors the loader's rule (readable, non-empty) so the pane and the
  /// terminal agree on whether the file is in effect.
  static var hasContent: Bool {
    SupacodePaths.ghosttyUserConfigHasContent()
  }

  /// True when the config declares a `config-file` include. Supacode does not
  /// resolve these (see the tier note in GhosttyRuntime), so the pane warns.
  static var declaresConfigFileInclude: Bool {
    guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return false }
    for line in contents.split(whereSeparator: \.isNewline) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { continue }
      if trimmed[..<equals].trimmingCharacters(in: .whitespaces) == "config-file" { return true }
    }
    return false
  }

  /// A comment-only starter so the file is never zero-byte (an empty file counts as absent).
  static let template = """
    # Supacode Ghostty config.
    # In merge mode these settings are read after your main Ghostty config, so
    # they override conflicts and merge the rest. In exclusive mode this file is
    # read on its own. Anything Ghostty understands works here.
    # Example:
    # theme = catppuccin-mocha
    # font-size = 14
    """

  static func createWithTemplateIfNeeded() throws {
    guard !hasContent else { return }
    try FileManager.default.createDirectory(
      at: SupacodePaths.baseDirectory, withIntermediateDirectories: true)
    try (template + "\n").write(to: url, atomically: true, encoding: .utf8)
  }
}

public struct TerminalSettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>
  let standardConfigPath: String?
  let reloadTerminalConfig: () -> Void

  /// `standardConfigPath` and `reloadTerminalConfig` are injected by the app
  /// layer (they reach GhosttyKit, which this module does not depend on).
  public init(
    store: StoreOf<SettingsFeature>,
    standardConfigPath: String?,
    reloadTerminalConfig: @escaping () -> Void
  ) {
    self.store = store
    self.standardConfigPath = standardConfigPath
    self.reloadTerminalConfig = reloadTerminalConfig
  }

  public var body: some View {
    Form {
      Section {
        Toggle(isOn: $store.terminalThemeSyncEnabled) {
          Text("Supacode terminal theme")
          Text("When off, honors your Ghostty config theme.")
        }
      }
      Section("Persistence") {
        Toggle(isOn: $store.terminateSessionsOnQuit) {
          Text("Terminate sessions on quit")
          Text(
            """
            Close all tabs and stop background shells when quitting.
            Terminal persistence is powered by [zmx\u{00A0}\u{2197}](https://github.com/neurosnap/zmx).
            """
          )
        }
        Toggle(isOn: $store.terminalHibernationEnabled) {
          HStack(spacing: 6) {
            Text("Hibernate inactive terminals")
            BetaBadge()
          }
          Text(
            "Background terminal tabs release their renderer after a few minutes of inactivity "
              + "and reconnect instantly when viewed. Sessions and running agents are unaffected."
          )
        }
      }
      Section {
        Toggle(isOn: $store.remoteSessionPersistenceEnabled) {
          HStack(spacing: 6) {
            Text("Persist sessions on remote host")
            BetaBadge()
          }
          Text(
            """
            Keeps SSH sessions alive across disconnects. Ignored when \
            [zmx\u{00A0}\u{2197}](https://github.com/neurosnap/zmx) is not installed on the host.
            """
          )
        }
      }
      GhosttyConfigurationSection(
        store: store,
        standardConfigPath: standardConfigPath,
        reloadTerminalConfig: reloadTerminalConfig
      )
    }
    .formStyle(.grouped)
    .contentMargins(.trailing, 6, for: .scrollIndicators)
    .padding(.top, -20)
    .padding(.leading, -8)
    .padding(.trailing, -6)
    .navigationTitle("Terminal")
  }
}

/// The Ghostty configuration section: where the config is read from, plus the
/// optional Supacode config and its merge/exclusive mode.
private struct GhosttyConfigurationSection: View {
  @Bindable var store: StoreOf<SettingsFeature>
  let standardConfigPath: String?
  let reloadTerminalConfig: () -> Void

  @State private var supacodeConfigHasContent = false
  @State private var declaresConfigFileInclude = false
  @State private var createErrorMessage: String?

  private var isExclusiveActive: Bool {
    store.ghosttyUserConfigMode == .exclusive && supacodeConfigHasContent
  }

  var body: some View {
    Section {
      ConfigSourceRow(
        title: "Ghostty config",
        path: standardConfigPath,
        isIgnored: isExclusiveActive
      )
      if supacodeConfigHasContent {
        SupacodeConfigPresentRows(store: store)
      } else {
        SupacodeConfigMissingRow(onCreate: createSupacodeConfig)
      }
      if declaresConfigFileInclude {
        Label(
          "`config-file` includes here may not apply. Put their settings directly in this file instead.",
          systemImage: "exclamationmark.triangle"
        )
        .appFont(.caption)
        .foregroundStyle(.secondary)
      }
      if let createErrorMessage {
        Label(
          "Could not create the Supacode config: \(createErrorMessage)",
          systemImage: "exclamationmark.triangle"
        )
        .appFont(.caption)
        .foregroundStyle(.secondary)
      }
    } header: {
      Text("Ghostty Configuration")
    } footer: {
      Text(
        "Configs apply top to bottom, so a later one overrides an earlier one. "
          + "Some changes take effect only in new terminals."
      )
    }
    .task { refresh() }
  }

  private func refresh() {
    supacodeConfigHasContent = GhosttyUserConfigFile.hasContent
    declaresConfigFileInclude = GhosttyUserConfigFile.declaresConfigFileInclude
  }

  private func createSupacodeConfig() {
    do {
      try GhosttyUserConfigFile.createWithTemplateIfNeeded()
    } catch {
      createErrorMessage = error.localizedDescription
      SupaLogger("Settings").error(
        "Failed to create Supacode Ghostty config: \(error.localizedDescription)")
      return
    }
    createErrorMessage = nil
    refresh()
    // Rebuild so the new file takes effect (in exclusive mode its presence now
    // suppresses the standard config).
    reloadTerminalConfig()
    // A bare .config file often has no default app; reveal it rather than fail silently.
    if !NSWorkspace.shared.open(GhosttyUserConfigFile.url) {
      NSWorkspace.shared.activateFileViewerSelecting([GhosttyUserConfigFile.url])
    }
  }
}

/// Rows shown once `~/.supacode/ghostty.config` exists: its path plus the
/// merge/exclusive mode picker.
private struct SupacodeConfigPresentRows: View {
  @Bindable var store: StoreOf<SettingsFeature>

  var body: some View {
    ConfigSourceRow(
      title: "Supacode config",
      path: GhosttyUserConfigFile.url.path,
      isIgnored: false
    )
    Picker(selection: $store.ghosttyUserConfigMode) {
      ForEach(GhosttyUserConfigMode.allCases, id: \.self) { mode in
        DefaultTaggedLabel(label: mode.label, isDefault: mode == .mergeAfterDefault)
          .tag(mode)
      }
    } label: {
      Text("Config mode")
      Text(store.ghosttyUserConfigMode.subtitle)
    }
  }
}

private struct SupacodeConfigMissingRow: View {
  let onCreate: () -> Void

  var body: some View {
    LabeledContent {
      Button("Create and Open", action: onCreate)
        .help("Create ~/.supacode/ghostty.config and open it in your editor")
    } label: {
      Text("Supacode config")
      Text("An extra Ghostty config applied only inside Supacode.")
    }
  }
}

/// One config-source row: a monospaced path plus a Reveal affordance.
private struct ConfigSourceRow: View {
  let title: String
  let path: String?
  let isIgnored: Bool

  private var fileExists: Bool {
    guard let path else { return false }
    return FileManager.default.fileExists(atPath: path)
  }

  var body: some View {
    LabeledContent {
      HStack(spacing: 10) {
        if let path {
          Text(path)
            .appFont(.caption)
            .monospaced()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        } else {
          Text("Not created yet")
            .appFont(.caption)
            .foregroundStyle(.tertiary)
        }
        if fileExists {
          Button {
            revealInFinder()
          } label: {
            Label("Reveal in Finder", systemImage: "folder")
              .labelStyle(.iconOnly)
          }
          .buttonStyle(.borderless)
          .help("Reveal \(title) in Finder")
        }
      }
    } label: {
      HStack(spacing: 6) {
        Text(title)
        if isIgnored {
          CapsuleBadge("Ignored")
        }
      }
    }
    .opacity(isIgnored ? 0.55 : 1)
  }

  private func revealInFinder() {
    guard let path else { return }
    NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
  }
}
