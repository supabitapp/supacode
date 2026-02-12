import ComposableArchitecture
import SwiftUI

struct ArchivedWorktreesDetailView: View {
  @Bindable var store: StoreOf<RepositoriesFeature>
  @State private var collapsedRepositoryIDs: Set<Repository.ID> = []
  @State private var selectedArchivedWorktreeIDs: Set<Worktree.ID> = []

  var body: some View {
    let groups = store.state.archivedWorktreesByRepository()
    let groupIDs = Set(groups.map(\.repository.id))
    let archivedRowIDs = groups.flatMap(\.worktrees).map(\.id)
    let archivedWorktreeIDs = Set(groups.flatMap(\.worktrees).map(\.id))
    let repositoryByWorktreeID = Dictionary(
      uniqueKeysWithValues: groups.flatMap { group in
        group.worktrees.map { worktree in
          (worktree.id, group.repository.id)
        }
      }
    )
    let selectedTargets: [RepositoriesFeature.DeleteWorktreeTarget] =
      selectedArchivedWorktreeIDs.compactMap { worktreeID in
        guard let repositoryID = repositoryByWorktreeID[worktreeID] else { return nil }
        return RepositoriesFeature.DeleteWorktreeTarget(
          worktreeID: worktreeID,
          repositoryID: repositoryID
        )
      }
    let deleteWorktreeAction: (() -> Void)? = {
      guard !selectedTargets.isEmpty else { return nil }
      return {
        store.send(.requestDeleteWorktrees(selectedTargets))
      }
    }()
    let confirmWorktreeAction: (() -> Void)? = {
      guard let alert = store.state.confirmWorktreeAlert else { return nil }
      return {
        store.send(.alert(.presented(alert)))
      }
    }()
    if groups.isEmpty {
      ContentUnavailableView(
        "Archived Worktrees",
        systemImage: "archivebox",
        description: Text("Archive worktrees to keep them out of the main list.")
      )
    } else {
      List(selection: $selectedArchivedWorktreeIDs) {
        ForEach(Array(groups.enumerated()), id: \.element.repository.id) { index, group in
          Section {
            if !collapsedRepositoryIDs.contains(group.repository.id) {
              ForEach(group.worktrees, id: \.id) { worktree in
                ArchivedWorktreeRowView(
                  worktree: worktree,
                  info: store.state.worktreeInfo(for: worktree.id),
                  onUnarchive: {
                    store.send(.unarchiveWorktree(worktree.id))
                  },
                  onDelete: {
                    store.send(.requestDeleteWorktree(worktree.id, group.repository.id))
                  }
                )
                .tag(worktree.id)
                .typeSelectEquivalent("")
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
              }
            }
          } header: {
            ArchivedWorktreeSectionHeader(
              name: group.repository.name,
              worktreeCount: group.worktrees.count,
              isCollapsed: collapsedRepositoryIDs.contains(group.repository.id),
              showsTopSeparator: index > 0,
              onToggle: { toggleSection(group.repository.id) }
            )
          }
        }
      }
      .listStyle(.sidebar)
      .onChange(of: groupIDs) { _, newValue in
        collapsedRepositoryIDs = collapsedRepositoryIDs.intersection(newValue)
      }
      .onChange(of: archivedWorktreeIDs) { _, newValue in
        selectedArchivedWorktreeIDs = selectedArchivedWorktreeIDs.intersection(newValue)
      }
      .animation(.easeOut(duration: 0.2), value: archivedRowIDs)
      .focusedSceneValue(\.deleteWorktreeAction, deleteWorktreeAction)
      .focusedSceneValue(\.confirmWorktreeAction, confirmWorktreeAction)
      .toolbar {
        let deleteShortcut = KeyboardShortcut(.delete, modifiers: [.command, .shift]).display
        Button("Delete Selected", systemImage: "trash", role: .destructive) {
          deleteWorktreeAction?()
        }
        .help("Delete Selected (\(deleteShortcut))")
        .disabled(deleteWorktreeAction == nil)
      }
    }
  }

  private func toggleSection(_ repositoryID: Repository.ID) {
    withAnimation(.easeOut(duration: 0.2)) {
      if collapsedRepositoryIDs.contains(repositoryID) {
        collapsedRepositoryIDs.remove(repositoryID)
      } else {
        collapsedRepositoryIDs.insert(repositoryID)
      }
    }
  }
}

private struct ArchivedWorktreeSectionHeader: View {
  let name: String
  let worktreeCount: Int
  let isCollapsed: Bool
  let showsTopSeparator: Bool
  let onToggle: () -> Void

  var body: some View {
    Button {
      onToggle()
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "chevron.right")
          .font(.caption2)
          .rotationEffect(.degrees(isCollapsed ? 0 : 90))
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Text(name)
          .font(.headline)
          .foregroundStyle(.primary)
          .lineLimit(1)
        Text("(\(worktreeCount))")
          .font(.headline)
          .foregroundStyle(.secondary)
        Spacer()
      }
      .padding(.top, 6)
      .contentShape(.rect)
    }
    .overlay(alignment: .top) {
      if showsTopSeparator {
        Rectangle()
          .fill(.secondary)
          .frame(height: 1)
          .frame(maxWidth: .infinity)
          .accessibilityHidden(true)
      }
    }
    .buttonStyle(.plain)
    .help(isCollapsed ? "Expand repository section" : "Collapse repository section")
    .textCase(nil)
  }
}
