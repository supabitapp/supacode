import ComposableArchitecture
import SwiftUI

struct ShortcutSettingsView: View {
  let store: StoreOf<SettingsFeature>

  private struct ShortcutGroup {
    let title: String
    let shortcuts: [AppShortcut]
  }

  private var groups: [ShortcutGroup] {
    [
      ShortcutGroup(title: "Sidebar", shortcuts: [
        AppShortcuts.toggleLeftSidebar,
      ]),
      ShortcutGroup(title: "Worktrees", shortcuts: [
        AppShortcuts.newWorktree,
        AppShortcuts.refreshWorktrees,
        AppShortcuts.archivedWorktrees,
        AppShortcuts.selectNextWorktree,
        AppShortcuts.selectPreviousWorktree,
      ]),
      ShortcutGroup(title: "Worktree Selection", shortcuts:
        AppShortcuts.worktreeSelection
      ),
      ShortcutGroup(title: "Actions", shortcuts: [
        AppShortcuts.openFinder,
        AppShortcuts.openRepository,
        AppShortcuts.openPullRequest,
        AppShortcuts.copyPath,
        AppShortcuts.runScript,
        AppShortcuts.stopRunScript,
      ]),
      ShortcutGroup(title: "General", shortcuts: [
        AppShortcuts.openSettings,
        AppShortcuts.checkForUpdates,
      ]),
    ]
  }

  var body: some View {
    VStack(alignment: .leading) {
      Form {
        ForEach(groups, id: \.title) { group in
          Section(group.title) {
            ForEach(group.shortcuts, id: \.name) { shortcut in
              HStack {
                Text(shortcut.displayName)
                  .frame(minWidth: 180, alignment: .leading)
                ShortcutRecorderView(
                  shortcutName: shortcut.name,
                  defaultShortcut: shortcut,
                  override: overrideBinding(for: shortcut.name),
                  existingOverrides: store.shortcutOverrides,
                  allDefaults: AppShortcuts.all
                )
              }
            }
          }
        }
      }
      .formStyle(.grouped)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private func overrideBinding(for name: String) -> Binding<AppShortcutOverride?> {
    Binding(
      get: { store.shortcutOverrides[name] },
      set: { newValue in
        store.send(.setShortcutOverride(name: name, override: newValue))
      }
    )
  }
}
