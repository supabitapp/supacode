import ComposableArchitecture
import Sharing
import SupacodeSettingsShared
import SwiftUI

struct SidebarView: View {
  @Bindable var store: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager
  @Shared(.settingsFile) private var settingsFile

  var body: some View {
    let state = store.state
    let confirmAlert = state.confirmWorktreeAlert
    // Reducer-cached: deriving these from `sidebarItems` here would
    // observation-track every row and fan per-leaf ticks out to the whole List.
    let archiveTargets = state.sidebarSelectionSlice.archiveTargets
    let deleteTargets = state.sidebarSelectionSlice.deleteTargets
    let openRepo = AppShortcuts.openRepository.effective(from: settingsFile.global.shortcutOverrides)

    return SidebarListView(
      store: store,
      terminalManager: terminalManager
    )
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Menu {
          Button {
            store.send(.setOpenPanelPresented(true))
          } label: {
            Label("Local Repository or Folder…", systemImage: "laptopcomputer")
          }
          .help("Add a local repository or folder (\(openRepo?.display ?? "none"))")
          Button {
            store.send(.requestAddRemoteRepository)
          } label: {
            Label("Remote Repository or Folder…", systemImage: "wifi")
          }
          .help("Add a repository or folder on an SSH host")
          Divider()
          Button {
            store.send(.requestCloneRepository)
          } label: {
            Label("Clone Repository…", systemImage: "square.and.arrow.down.on.square")
          }
          .help("Clone a remote repository into a local folder")
        } label: {
          Label {
            Text("Add…")
          } icon: {
            Image(systemName: "folder.badge.plus")
              .offset(y: -1)
              .accessibilityHidden(true)
          }
        }
        .menuIndicator(.hidden)
        .labelStyle(.iconOnly)
        .help("Add Repository, Folder, or Remote")
      }
    }
    .sheet(item: $store.scope(state: \.remoteConnectionForm, action: \.remoteConnectionForm)) { formStore in
      RemoteConnectionFormView(store: formStore)
    }
    .sheet(item: $store.scope(state: \.cloneRepositoryForm, action: \.cloneRepositoryForm)) { formStore in
      CloneRepositoryFormView(store: formStore)
    }
    .focusedSceneAction(
      \.confirmWorktreeAction,
      enabled: confirmAlert != nil,
      token: confirmAlert
    ) {
      if let alert = confirmAlert {
        store.send(.alert(.presented(alert)))
      }
    }
    .focusedAction(
      \.archiveWorktreeAction,
      enabled: !archiveTargets.isEmpty,
      token: archiveTargets
    ) {
      if archiveTargets.count == 1, let target = archiveTargets.first {
        store.send(.requestArchiveWorktree(target.worktreeID, target.repositoryID))
      } else {
        store.send(.requestArchiveWorktrees(archiveTargets))
      }
    }
    .focusedAction(
      \.deleteWorktreeAction,
      enabled: !deleteTargets.isEmpty,
      token: deleteTargets
    ) {
      store.send(.requestDeleteSidebarItems(deleteTargets))
    }
  }
}
