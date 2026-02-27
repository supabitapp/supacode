import ComposableArchitecture
import SwiftUI

struct ShortcutSettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>

  @State private var recordingShortcutName: String?
  @State private var searchText = ""
  @State private var showRestoreConfirmation = false

  private struct ShortcutGroup {
    let title: String
    let shortcuts: [AppShortcut]
  }

  private var groups: [ShortcutGroup] {
    let allGroups = [
      ShortcutGroup(title: "Sidebar", shortcuts: [
        AppShortcuts.toggleLeftSidebar,
      ]),
      ShortcutGroup(title: "Worktrees", shortcuts: [
        AppShortcuts.newWorktree,
        AppShortcuts.refreshWorktrees,
        AppShortcuts.archivedWorktrees,
        AppShortcuts.archiveWorktree,
        AppShortcuts.deleteWorktree,
        AppShortcuts.confirmWorktreeAction,
        AppShortcuts.selectNextWorktree,
        AppShortcuts.selectPreviousWorktree,
      ]),
      ShortcutGroup(title: "Worktree Selection", shortcuts:
        AppShortcuts.worktreeSelection
      ),
      ShortcutGroup(title: "Find", shortcuts: [
        AppShortcuts.find,
        AppShortcuts.findNext,
        AppShortcuts.findPrevious,
        AppShortcuts.hideFindBar,
        AppShortcuts.useSelectionForFind,
      ]),
      ShortcutGroup(title: "Actions", shortcuts: [
        AppShortcuts.openFinder,
        AppShortcuts.openRepository,
        AppShortcuts.openPullRequest,
        AppShortcuts.copyPath,
        AppShortcuts.runScript,
        AppShortcuts.stopRunScript,
      ]),
      ShortcutGroup(title: "General", shortcuts: [
        AppShortcuts.commandPalette,
        AppShortcuts.openSettings,
        AppShortcuts.checkForUpdates,
      ]),
    ]

    if searchText.isEmpty { return allGroups }

    let query = searchText.lowercased()
    return allGroups.compactMap { group in
      let filtered = group.shortcuts.filter { shortcut in
        shortcut.displayName.lowercased().contains(query)
          || shortcut.display.lowercased().contains(query)
      }
      return filtered.isEmpty ? nil : ShortcutGroup(title: group.title, shortcuts: filtered)
    }
  }

  private var needsRestart: Bool {
    ShortcutRestartState.requiresRestart(current: store.shortcutOverrides)
  }

  private var hasAnyOverrides: Bool {
    !store.shortcutOverrides.isEmpty
  }

  private var warningsByName: [String: String] {
    var warnings: [String: String] = [:]
    let overrides = store.shortcutOverrides

    let reserved: [(display: String, label: String)] = [
      ("⌘Q", "⌘Q"), ("⌘W", "⌘W"), ("⌘H", "⌘H"),
      ("⌘M", "⌘M"), ("⌘␠", "⌘Space"), ("⌘⇥", "⌘Tab"),
    ]

    var displayToNames: [String: [String]] = [:]
    for shortcut in AppShortcuts.all {
      let display: String
      if let ovr = overrides[shortcut.name] {
        if ovr.isUnbound { continue }
        display = ovr.displayString
      } else {
        display = shortcut.display
      }
      displayToNames[display, default: []].append(shortcut.name)

      for entry in reserved where display == entry.display {
        warnings[shortcut.name] = "\(entry.label) is reserved by the system"
      }
    }

    for (_, names) in displayToNames where names.count > 1 {
      for name in names {
        let others = names.filter { $0 != name }
        let otherLabels = others.compactMap { otherName in
          AppShortcuts.all.first { $0.name == otherName }?.displayName
        }
        let existing = warnings[name].map { $0 + ". " } ?? ""
        warnings[name] = existing + "Conflicts with \(otherLabels.joined(separator: ", "))"
      }
    }

    return warnings
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if needsRestart {
        restartBanner
      }
      Form {
        ForEach(groups, id: \.title) { group in
          Section(group.title) {
            ForEach(group.shortcuts, id: \.name) { shortcut in
              LabeledContent {
                ShortcutRecorderView(
                  shortcutName: shortcut.name,
                  defaultShortcut: shortcut,
                  currentOverride: store.shortcutOverrides[shortcut.name],
                  isRecording: recordingShortcutName == shortcut.name,
                  setRecording: { recording in
                    recordingShortcutName = recording ? shortcut.name : nil
                  },
                  onOverrideChanged: { newValue in
                    store.send(.setShortcutOverride(name: shortcut.name, override: newValue))
                  },
                  warning: warningsByName[shortcut.name]
                )
              } label: {
                Text(shortcut.displayName)
              }
            }
          }
        }
      }
      .formStyle(.grouped)

      if hasAnyOverrides {
        HStack {
          Button("Restore All Defaults") {
            showRestoreConfirmation = true
          }
          .help("Reset all shortcuts to their default values")
          .confirmationDialog(
            "Restore all keyboard shortcuts to their defaults?",
            isPresented: $showRestoreConfirmation,
            titleVisibility: .visible
          ) {
            Button("Restore Defaults", role: .destructive) {
              for shortcut in AppShortcuts.all {
                store.send(.setShortcutOverride(name: shortcut.name, override: nil))
              }
            }
          }
          Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
      }
    }
    .searchable(text: $searchText, placement: .toolbar, prompt: "Filter shortcuts")
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var restartBanner: some View {
    HStack(spacing: 8) {
      Image(systemName: "arrow.trianglehead.2.counterclockwise")
        .foregroundStyle(.secondary)
      Text("Restart required to apply shortcut changes to the terminal")
        .font(.callout)
      Spacer()
      Button("Restart") {
        relaunch()
      }
      .help("Restart Supacode to apply shortcut changes")
    }
    .padding(12)
    .background(.quinary, in: .rect(cornerRadius: 8))
    .padding([.horizontal, .top])
  }

  private func relaunch() {
    let url = Bundle.main.bundleURL
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
      NSApplication.shared.terminate(nil)
    }
  }
}
