import ComposableArchitecture
import SwiftUI

struct TaskRowsView: View {
  let repository: Repository
  let isExpanded: Bool
  @Bindable var store: StoreOf<RepositoriesFeature>
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    if isExpanded {
      expandedRowsView
    }
  }

  private var expandedRowsView: some View {
    let state = store.state
    let sections = state.taskRowSections(in: repository)
    let isRepositoryRemoving = state.isRemovingRepository(repository)
    return Group {
      ForEach(sections.pending) { row in
        taskRowView(row, isRepositoryRemoving: isRepositoryRemoving)
      }
      ForEach(sections.tasks) { row in
        let baseRow = taskRowView(row, isRepositoryRemoving: isRepositoryRemoving)
        if !isRepositoryRemoving, !row.isDeleting {
          baseRow.contextMenu {
            taskContextMenu(row: row)
          }
        } else {
          baseRow.disabled(isRepositoryRemoving)
        }
      }
    }
    .environment(\.colorScheme, colorScheme)
    .preferredColorScheme(colorScheme)
  }

  @ViewBuilder
  private func taskRowView(_ row: TaskRowModel, isRepositoryRemoving: Bool) -> some View {
    let isSelected = row.id == store.state.selectedTaskID
    TaskRowView(row: row, isSelected: isSelected)
      .tag(SidebarSelection.task(row.id))
      .typeSelectEquivalent("")
      .listRowInsets(EdgeInsets())
      .transition(.opacity)
  }

  @ViewBuilder
  private func taskContextMenu(row: TaskRowModel) -> some View {
    Button("Archive Task") {
      store.send(.archiveTask(row.id))
    }
    .help("Archive Task")
    Button("Delete Task", role: .destructive) {
      store.send(.requestDeleteTask(row.id, row.repositoryID))
    }
    .help("Delete Task")
  }
}
