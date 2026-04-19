import AppKit
import ComposableArchitecture
import Sharing
import SupacodeSettingsShared
import SwiftUI

struct SidebarListView: View {
  @Bindable var store: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager
  @FocusState private var isSidebarFocused: Bool

  var body: some View {
    let state = store.state
    let expandedRepoIDs = state.expandedRepositoryIDs
    let hotkeyRows = state.orderedWorktreeRows(includingRepositoryIDs: expandedRepoIDs)
    let orderedRoots = state.orderedRepositoryRoots()
    let selectedWorktreeIDs = state.sidebarSelectedWorktreeIDs
    let currentSelections = state.sidebarSelections
    let selection = Binding<Set<SidebarSelection>>(
      get: { currentSelections },
      set: { newValue in
        guard newValue != currentSelections else { return }
        store.send(.selectionChanged(newValue))
      }
    )
    let repositoriesByID = Dictionary(uniqueKeysWithValues: store.repositories.map { ($0.id, $0) })
    let pendingSidebarReveal = state.pendingSidebarReveal

    return ScrollViewReader { scrollProxy in
      List(selection: selection) {
        if !state.isInitialLoadComplete, store.repositories.isEmpty {
          SidebarPlaceholderView()
        } else if orderedRoots.isEmpty {
          ForEach(store.repositories) { repository in
            if repository.isGitRepository {
              SidebarRepositorySectionView(
                repository: repository,
                hotkeyRows: hotkeyRows,
                selectedWorktreeIDs: selectedWorktreeIDs,
                store: store,
                terminalManager: terminalManager
              )
            } else {
              SidebarFolderSectionView(repository: repository, store: store)
            }
          }
        } else {
          ForEach(sidebarRootRows(from: orderedRoots), id: \.repositoryID) { row in
            if let failureMessage = state.loadFailuresByID[row.repositoryID] {
              SidebarFailedRepositoryRow(
                rootURL: row.rootURL,
                failureMessage: failureMessage,
                store: store
              )
            } else if let repository = repositoriesByID[row.repositoryID] {
              if repository.isGitRepository {
                SidebarRepositorySectionView(
                  repository: repository,
                  hotkeyRows: hotkeyRows,
                  selectedWorktreeIDs: selectedWorktreeIDs,
                  store: store,
                  terminalManager: terminalManager
                )
              } else {
                SidebarFolderSectionView(repository: repository, store: store)
              }
            }
          }
          .onMove { offsets, destination in
            store.send(.repositoriesMoved(offsets, destination))
          }
        }
      }
      .listStyle(.sidebar)
      .focused($isSidebarFocused)
      .frame(minWidth: 220)
      .dropDestination(for: URL.self) { urls, _ in
        let fileURLs = urls.filter(\.isFileURL)
        guard !fileURLs.isEmpty else { return false }
        store.send(.openRepositories(fileURLs))
        return true
      }
      .onKeyPress { keyPress in
        guard !keyPress.characters.isEmpty else { return .ignored }
        let navigationKeys: Set<KeyEquivalent> = [
          .upArrow, .downArrow, .leftArrow, .rightArrow,
          .home, .end, .pageUp, .pageDown,
        ]
        guard !navigationKeys.contains(keyPress.key) else { return .ignored }
        let hasCommandModifier = keyPress.modifiers.contains(.command)
        if hasCommandModifier { return .ignored }
        guard let worktreeID = store.selectedWorktreeID,
          state.sidebarSelectedWorktreeIDs.count == 1,
          state.sidebarSelectedWorktreeIDs.contains(worktreeID),
          let terminalState = terminalManager.stateIfExists(for: worktreeID)
        else { return .ignored }
        terminalState.focusAndInsertText(keyPress.characters)
        return .handled
      }
      .task(id: pendingSidebarReveal?.id) {
        await revealPendingSidebarWorktree(pendingSidebarReveal, with: scrollProxy)
      }
    }
  }

  private func sidebarRootRows(
    from orderedRoots: [URL]
  ) -> [(rootURL: URL, repositoryID: Repository.ID)] {
    orderedRoots.map { rootURL in
      (
        rootURL: rootURL,
        repositoryID: rootURL.standardizedFileURL.path(percentEncoded: false)
      )
    }
  }

  @MainActor
  private func revealPendingSidebarWorktree(
    _ pendingSidebarReveal: RepositoriesFeature.PendingSidebarReveal?,
    with scrollProxy: ScrollViewProxy
  ) async {
    guard let pendingSidebarReveal else { return }
    // Give SwiftUI time to materialize newly expanded section rows before scrolling.
    await Task.yield()
    await Task.yield()
    isSidebarFocused = true
    withAnimation(.easeOut(duration: 0.2)) {
      scrollProxy.scrollTo(pendingSidebarReveal.worktreeID, anchor: .center)
    }
    store.send(.consumePendingSidebarReveal(pendingSidebarReveal.id))
  }
}

private struct SidebarRepositorySectionView: View {
  let repository: Repository
  let hotkeyRows: [WorktreeRowModel]
  let selectedWorktreeIDs: Set<Worktree.ID>
  @Bindable var store: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager
  var body: some View {
    let isRemovingRepository = store.state.isRemovingRepository(repository)
    Section(isExpanded: repositoryExpansionBinding) {
      WorktreeRowsView(
        repository: repository,
        hotkeyRows: hotkeyRows,
        selectedWorktreeIDs: selectedWorktreeIDs,
        store: store,
        terminalManager: terminalManager
      )
    } header: {
      RepoSectionHeaderView(
        name: repository.name,
        isRemoving: isRemovingRepository
      )
    }
    .sectionActions {
      SidebarRepositorySectionActionsView(
        repositoryID: repository.id,
        isRemovingRepository: isRemovingRepository,
        store: store
      )
    }
  }

  private var repositoryExpansionBinding: Binding<Bool> {
    Binding(
      get: { store.state.isRepositoryExpanded(repository.id) },
      set: { isExpanded in
        store.send(.repositoryExpansionChanged(repository.id, isExpanded: isExpanded))
      }
    )
  }
}

private struct SidebarRepositorySectionActionsView: View {
  let repositoryID: Repository.ID
  let isRemovingRepository: Bool
  let store: StoreOf<RepositoriesFeature>

  var body: some View {
    Menu {
      Button("Repository Settings…", systemImage: "gear") {
        store.send(.openRepositorySettings(repositoryID))
      }
      .help("Repository Settings")
      Divider()
      Button("Remove Repository…", systemImage: "folder.badge.minus", role: .destructive) {
        store.send(.requestRemoveRepository(repositoryID))
      }
      .help("Remove Repository")
      .disabled(isRemovingRepository)
    } label: {
      Image(systemName: "ellipsis")
        .accessibilityLabel("Options")
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
    }
    .menuStyle(.button)
    .menuIndicator(.hidden)
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)

    Button {
      store.send(.createRandomWorktreeInRepository(repositoryID))
    } label: {
      Image(systemName: "plus")
        .accessibilityLabel("New Worktree")
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(isRemovingRepository)
    .foregroundStyle(.secondary)
    .help("New Worktree")
    .padding(.trailing, 4)
  }
}

private struct SidebarFolderSectionView: View {
  let repository: Repository
  @Bindable var store: StoreOf<RepositoriesFeature>

  var body: some View {
    let isRemovingRepository = store.state.isRemovingRepository(repository)
    Section {
      Label {
        HStack(spacing: 6) {
          Text(repository.name)
            .fontWeight(.semibold)
          if isRemovingRepository {
            ProgressView()
              .controlSize(.small)
              .accessibilityLabel("Removing folder")
          }
        }
      } icon: {
        Image(systemName: "folder")
          .accessibilityHidden(true)
      }
      .labelStyle(.verticallyCentered)
      .tag(SidebarSelection.worktree(Repository.folderWorktreeID(for: repository.rootURL)))
      .contextMenu {
        FolderContextMenu(
          repository: repository,
          store: store,
          isRemovingRepository: isRemovingRepository
        )
      }
      .disabled(isRemovingRepository)
    }
  }
}

// MARK: - Folder context menu.

/// Mirrors `WorktreeContextMenu` item-by-item, applies the
/// main-worktree limitations (no pin, no archive) since a folder's
/// synthetic worktree is always main, drops the git-specific
/// "Copy as Branch Name" item, and uses "Folder" copy for the
/// destructive action. Delete routes through
/// `.requestDeleteWorktree` so the existing blocking-script +
/// delete pipeline handles the delete-script → sidebar removal
/// sequence (the reducer branches on `isGitRepository` to skip the
/// git `removeWorktree` step that makes no sense for folders).
private struct FolderContextMenu: View {
  let repository: Repository
  @Bindable var store: StoreOf<RepositoriesFeature>
  let isRemovingRepository: Bool
  @Shared(.settingsFile) private var settingsFile

  private var worktreeID: Worktree.ID {
    Repository.folderWorktreeID(for: repository.rootURL)
  }

  private var openActionSelection: OpenWorktreeAction {
    @Shared(.repositorySettings(repository.rootURL)) var repositorySettings
    return OpenWorktreeAction.fromSettingsID(
      repositorySettings.openActionID,
      defaultEditorID: settingsFile.global.defaultEditorID
    )
  }

  var body: some View {
    let overrides = settingsFile.global.shortcutOverrides
    let deleteShortcut = AppShortcuts.deleteWorktree.effective(from: overrides)

    openActions(overrides: overrides)
    Divider()

    Button("Copy as Pathname", systemImage: "doc.on.doc") {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(repository.rootURL.path, forType: .string)
    }
    Divider()

    // Folder rows have an empty section header (no ellipsis menu),
    // so the "Folder Settings…" entry lives in the context menu
    // alongside Delete — mirroring the repo section actions.
    Button("Folder Settings…", systemImage: "gear") {
      store.send(.openRepositorySettings(repository.id))
    }
    .help("Folder Settings")

    Button("Remove Folder…", systemImage: "trash", role: .destructive) {
      store.send(.requestDeleteWorktree(worktreeID, repository.id))
    }
    .appKeyboardShortcut(deleteShortcut)
    .help("Remove Folder")
    .disabled(isRemovingRepository)
  }

  @ViewBuilder
  private func openActions(overrides: [AppShortcutID: AppShortcutOverride]) -> some View {
    let availableActions = OpenWorktreeAction.availableCases.filter { $0 != .finder }
    let resolved = OpenWorktreeAction.availableSelection(openActionSelection)
    let primarySelection = resolved == .finder ? availableActions.first : resolved
    let openShortcut = AppShortcuts.openWorktree.effective(from: overrides)
    let revealShortcut = AppShortcuts.revealInFinder.effective(from: overrides)

    if let primarySelection {
      Button("Open with \(primarySelection.labelTitle)", systemImage: "arrow.up.right.square") {
        store.send(.contextMenuOpenWorktree(worktreeID, primarySelection))
      }
      .appKeyboardShortcut(openShortcut)
      .help("Open with \(primarySelection.labelTitle) (\(openShortcut?.display ?? "none"))")
    }

    Menu("Open With") {
      ForEach(availableActions) { action in
        Button {
          store.send(.contextMenuOpenWorktree(worktreeID, action))
        } label: {
          OpenWorktreeActionMenuLabelView(action: action, shortcutHint: nil)
        }
        .help("Open with \(action.labelTitle)")
      }
    }

    Button("Reveal in Finder", systemImage: "folder") {
      store.send(.contextMenuOpenWorktree(worktreeID, .finder))
    }
    .appKeyboardShortcut(revealShortcut)
    .help("Reveal in Finder (\(revealShortcut?.display ?? "none"))")
  }
}

private struct SidebarFailedRepositoryRow: View {
  let rootURL: URL
  let failureMessage: String
  let store: StoreOf<RepositoriesFeature>

  var body: some View {
    let standardizedRootURL = rootURL.standardizedFileURL
    let name = Repository.name(for: standardizedRootURL)
    let path = standardizedRootURL.path(percentEncoded: false)

    FailedRepositoryRow(
      name: name,
      path: path,
      showFailure: {
        let message = "\(path)\n\n\(failureMessage)"
        store.send(.presentAlert(title: "Unable to load \(name)", message: message))
      },
      removeRepository: {
        store.send(.removeFailedRepository(path))
      }
    )
    .padding(.horizontal, 12)
  }
}

// MARK: - Sidebar placeholder.

private struct SidebarPlaceholderView: View {
  var body: some View {
    ForEach(0..<2, id: \.self) { section in
      Section {
        ForEach(0..<3, id: \.self) { _ in
          Label {
            VStack(alignment: .leading, spacing: 2) {
              Text("placeholder-branch")
                .font(.body)
                .lineLimit(1)
                .redacted(reason: .placeholder)
                .shimmer(isActive: true)
              Text("placeholder")
                .font(.footnote)
                .lineLimit(1)
                .redacted(reason: .placeholder)
                .shimmer(isActive: true)
            }
          } icon: {
            Image(systemName: "arrow.triangle.branch")
              .accessibilityHidden(true)
              .foregroundStyle(.secondary)
              .redacted(reason: .placeholder)
              .shimmer(isActive: true)
          }
        }
      } header: {
        Text(section == 0 ? "repository" : "second-repo")
          .foregroundStyle(.secondary)
          .redacted(reason: .placeholder)
          .shimmer(isActive: true)
      }
    }
  }
}
