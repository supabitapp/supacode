import ComposableArchitecture
import SwiftUI

struct RepositorySectionView: View {
  let repository: Repository
  let showsTopSeparator: Bool
  let isDragActive: Bool
  @Binding var expandedRepoIDs: Set<Repository.ID>
  let shortcutIndex: Int?
  let worktreeShortcutIndexByID: [Worktree.ID: Int]
  @Bindable var store: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager
  @Environment(CommandKeyObserver.self) private var commandKeyObserver
  @Environment(\.colorScheme) private var colorScheme
  @State private var isHovering = false

  var body: some View {
    let state = store.state
    let isExpanded = expandedRepoIDs.contains(repository.id)
    let isRemovingRepository = state.isRemovingRepository(repository)
    let openRepoSettings = {
      _ = store.send(.openRepositorySettings(repository.id))
    }
    let toggleExpanded = {
      guard !isRemovingRepository else { return }
      withAnimation(.easeOut(duration: 0.2)) {
        if isExpanded {
          expandedRepoIDs.remove(repository.id)
        } else {
          expandedRepoIDs.insert(repository.id)
        }
      }
    }
    let isDragging = isDragActive

    Group {
      HStack {
        RepoHeaderRow(
          name: repository.name,
          isRemoving: isRemovingRepository,
          shortcutHint: commandKeyObserver.isPressed && !isExpanded ? repositoryShortcutHint(for: shortcutIndex) : nil
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        if isRemovingRepository && !isDragging {
          ProgressView()
            .controlSize(.small)
        }
        if isHovering && !isDragging {
          Menu {
            Button("Repo Settings") {
              openRepoSettings()
            }
            .help("Repo Settings ")
            Button("Remove Repository") {
              store.send(.requestRemoveRepository(repository.id))
            }
            .help("Remove repository ")
            .disabled(isRemovingRepository)
          } label: {
            Label("Repository options", systemImage: "ellipsis")
              .labelStyle(.iconOnly)
              .frame(maxHeight: .infinity)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .help("Repository options ")
          .disabled(isRemovingRepository)
          Button {
            store.send(.createRandomWorktreeInRepository(repository.id))
          } label: {
            Label("New Worktree", systemImage: "plus")
              .labelStyle(.iconOnly)
              .frame(maxHeight: .infinity)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .help("New Worktree (\(AppShortcuts.newWorktree.display))")
          .disabled(isRemovingRepository)
          Button {
            toggleExpanded()
          } label: {
            Image(systemName: "chevron.right")
              .rotationEffect(.degrees(isExpanded ? 90 : 0))
              .frame(maxHeight: .infinity)
              .contentShape(Rectangle())
              .accessibilityLabel(isExpanded ? "Collapse" : "Expand")
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .help(isExpanded ? "Collapse" : "Expand")
        }
      }
      .frame(maxWidth: .infinity)
      .frame(height: headerCellHeight, alignment: .center)
      .overlay(alignment: .top) {
        if showsTopSeparator {
          Rectangle()
            .fill(.secondary)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
        }
      }
      .onHover { isHovering = $0 }
      .contentShape(.rect)
      .contextMenu {
        Button("Repo Settings") {
          openRepoSettings()
        }
        .help("Repo Settings ")
        Button("Remove Repository") {
          store.send(.requestRemoveRepository(repository.id))
        }
        .help("Remove repository ")
        .disabled(isRemovingRepository)
      }
      .contentShape(.dragPreview, .rect)
      .tag(SidebarSelection.repository(repository.id))
      .listRowBackground(Color.clear)
      .environment(\.colorScheme, colorScheme)
      .preferredColorScheme(colorScheme)

      if isExpanded {
        WorktreeRowsView(
          repository: repository,
          isExpanded: isExpanded,
          shortcutIndexByID: worktreeShortcutIndexByID,
          store: store,
          terminalManager: terminalManager
        )
      }
    }
  }

  private var headerCellHeight: CGFloat {
    46
  }

  private func repositoryShortcutHint(for index: Int?) -> String? {
    guard let index, AppShortcuts.worktreeSelection.indices.contains(index) else { return nil }
    return AppShortcuts.worktreeSelection[index].display
  }
}
