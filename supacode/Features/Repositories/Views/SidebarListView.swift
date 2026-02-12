import ComposableArchitecture
import SwiftUI

struct SidebarListView: View {
  @Bindable var store: StoreOf<RepositoriesFeature>
  @Binding var expandedRepoIDs: Set<Repository.ID>
  let terminalManager: WorktreeTerminalManager
  @State private var isDragActive = false

  var body: some View {
    let selection = Binding<SidebarSelection?>(
      get: {
        if store.isShowingArchivedWorktrees {
          return .archivedWorktrees
        }
        return store.selectedWorktreeID.map(SidebarSelection.worktree)
      },
      set: { newValue in
        switch newValue {
        case .archivedWorktrees:
          store.send(.selectArchivedWorktrees)
        case .worktree(let id):
          let isMouseEvent = NSApp.currentEvent?.type == .leftMouseUp
          store.send(.selectWorktree(id, focusTerminal: isMouseEvent))
        case .repository(let id):
          guard let repo = store.state.repositories[id: id],
            !store.state.isRemovingRepository(repo)
          else { return }
          withAnimation(.easeOut(duration: 0.2)) {
            if expandedRepoIDs.contains(id) {
              expandedRepoIDs.remove(id)
            } else {
              expandedRepoIDs.insert(id)
            }
          }
        case nil:
          store.send(.selectWorktree(nil))
        }
      }
    )
    let state = store.state
    let hotkeyRows = state.orderedWorktreeRows(includingRepositoryIDs: expandedRepoIDs)
    let orderedRoots = state.orderedRepositoryRoots()
    let repositoriesByID = Dictionary(uniqueKeysWithValues: store.repositories.map { ($0.id, $0) })
    List(selection: selection) {
      if orderedRoots.isEmpty {
        let repositories = store.repositories
        ForEach(Array(repositories.enumerated()), id: \.element.id) { index, repository in
          RepositorySectionView(
            repository: repository,
            showsTopSeparator: index > 0,
            isDragActive: isDragActive,
            hotkeyRows: hotkeyRows,
            expandedRepoIDs: $expandedRepoIDs,
            store: store,
            terminalManager: terminalManager
          )
          .listRowInsets(EdgeInsets())
        }
      } else {
        let orderedRows = Array(orderedRoots.enumerated()).map { index, rootURL in
          (
            index: index,
            rootURL: rootURL,
            repositoryID: rootURL.standardizedFileURL.path(percentEncoded: false)
          )
        }
        ForEach(orderedRows, id: \.repositoryID) { row in
          let index = row.index
          let rootURL = row.rootURL
          let repositoryID = row.repositoryID
          if let failureMessage = state.loadFailuresByID[repositoryID] {
            let name = Repository.name(for: rootURL.standardizedFileURL)
            let path = rootURL.standardizedFileURL.path(percentEncoded: false)
            FailedRepositoryRow(
              name: name,
              path: path,
              showFailure: {
                let message = "\(path)\n\n\(failureMessage)"
                store.send(.presentAlert(title: "Unable to load \(name)", message: message))
              },
              removeRepository: {
                store.send(.removeFailedRepository(repositoryID))
              }
            )
            .padding(.horizontal, 12)
            .overlay(alignment: .top) {
              if index > 0 {
                Rectangle()
                  .fill(.secondary)
                  .frame(height: 1)
                  .frame(maxWidth: .infinity)
                  .accessibilityHidden(true)
              }
            }
            .listRowInsets(EdgeInsets())
          } else if let repository = repositoriesByID[repositoryID] {
            RepositorySectionView(
              repository: repository,
              showsTopSeparator: index > 0,
              isDragActive: isDragActive,
              hotkeyRows: hotkeyRows,
              expandedRepoIDs: $expandedRepoIDs,
              store: store,
              terminalManager: terminalManager
            )
            .listRowInsets(EdgeInsets())
          }
        }
        .onMove { offsets, destination in
          store.send(.repositoriesMoved(offsets, destination))
        }
      }
    }
    .listStyle(.sidebar)
    .frame(minWidth: 220)
    .onDragSessionUpdated { session in
      if case .ended = session.phase {
        if isDragActive {
          isDragActive = false
        }
        return
      }
      if case .dataTransferCompleted = session.phase {
        if isDragActive {
          isDragActive = false
        }
        return
      }
      if !isDragActive {
        isDragActive = true
      }
    }
    .safeAreaInset(edge: .bottom) {
      SidebarFooterView(store: store)
    }
    .dropDestination(for: URL.self) { urls, _ in
      let fileURLs = urls.filter(\.isFileURL)
      guard !fileURLs.isEmpty else { return false }
      store.send(.openRepositories(fileURLs))
      return true
    }
    .onKeyPress { keyPress in
      guard !keyPress.characters.isEmpty else { return .ignored }
      let isNavigationKey =
        keyPress.key == .upArrow
        || keyPress.key == .downArrow
        || keyPress.key == .leftArrow
        || keyPress.key == .rightArrow
        || keyPress.key == .home
        || keyPress.key == .end
        || keyPress.key == .pageUp
        || keyPress.key == .pageDown
      if isNavigationKey { return .ignored }
      let hasCommandModifier = keyPress.modifiers.contains(.command)
      if hasCommandModifier { return .ignored }
      guard let worktreeID = store.selectedWorktreeID,
        let terminalState = terminalManager.stateIfExists(for: worktreeID)
      else { return .ignored }
      terminalState.focusAndInsertText(keyPress.characters)
      return .handled
    }
  }
}
