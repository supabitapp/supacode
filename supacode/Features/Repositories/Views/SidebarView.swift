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
    let visibleHotkeyRows = state.orderedSidebarItems(includingRepositoryIDs: state.expandedRepositoryIDs)
    let effectiveSelectedRows = state.effectiveSidebarSelectedRows
    let confirmWorktreeAction = makeConfirmWorktreeAction(state: state)
    let archiveWorktreeAction = makeArchiveWorktreeAction(rows: effectiveSelectedRows)
    let deleteWorktreeAction = makeDeleteWorktreeAction(rows: effectiveSelectedRows)
    let openRepo = AppShortcuts.openRepository.effective(from: settingsFile.global.shortcutOverrides)

    return SidebarListView(
      store: store,
      terminalManager: terminalManager
    )
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          store.send(.setOpenPanelPresented(true))
        } label: {
          Label {
            Text("Add…")
          } icon: {
            Image(systemName: "folder.badge.plus")
              .offset(y: -1)
              .accessibilityHidden(true)
          }
        }
        .labelStyle(.iconOnly)
        .help("Add Repository or Folder (\(openRepo?.display ?? "none"))")
      }
    }
    .focusedSceneValue(\.confirmWorktreeAction, confirmWorktreeAction)
    .focusedValue(\.archiveWorktreeAction, archiveWorktreeAction)
    .focusedValue(\.deleteWorktreeAction, deleteWorktreeAction)
    .focusedSceneValue(\.visibleHotkeyWorktreeRows, visibleHotkeyRows)
  }

  private func makeConfirmWorktreeAction(
    state: RepositoriesFeature.State
  ) -> (() -> Void)? {
    guard let alert = state.confirmWorktreeAlert else { return nil }
    return {
      store.send(.alert(.presented(alert)))
    }
  }

  private func makeArchiveWorktreeAction(
    rows: [SidebarItemModel]
  ) -> (() -> Void)? {
    let targets =
      rows
      .filter { $0.isRemovable && !$0.isMainWorktree }
      .map {
        RepositoriesFeature.ArchiveWorktreeTarget(
          worktreeID: $0.id,
          repositoryID: $0.repositoryID
        )
      }
    guard !targets.isEmpty else { return nil }
    return {
      if targets.count == 1, let target = targets.first {
        store.send(.requestArchiveWorktree(target.worktreeID, target.repositoryID))
      } else {
        store.send(.requestArchiveWorktrees(targets))
      }
    }
  }

  private func makeDeleteWorktreeAction(
    rows: [SidebarItemModel]
  ) -> (() -> Void)? {
    let targets =
      rows
      .filter { $0.isRemovable }
      .map {
        RepositoriesFeature.DeleteWorktreeTarget(
          worktreeID: $0.id,
          repositoryID: $0.repositoryID
        )
      }
    guard !targets.isEmpty else { return nil }
    return {
      store.send(.requestDeleteSidebarItems(targets))
    }
  }
}
