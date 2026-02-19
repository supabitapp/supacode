import ComposableArchitecture
import SwiftUI

struct SidebarListView: View {
  @Bindable var store: StoreOf<RepositoriesFeature>
  @Binding var expandedRepoIDs: Set<Repository.ID>
  @Binding var sidebarSelections: Set<SidebarSelection>
  let terminalManager: WorktreeTerminalManager
  @State private var isDragActive = false

  var body: some View {
    let state = store.state
    let hotkeyRows = state.orderedWorktreeRows(includingRepositoryIDs: expandedRepoIDs)
    let orderedRoots = state.orderedRepositoryRoots()
    let selectedWorktreeIDs = Set(sidebarSelections.compactMap(\.worktreeID))
    let selection = Binding<Set<SidebarSelection>>(
      get: {
        var nextSelections = sidebarSelections
        if state.isShowingArchivedWorktrees {
          nextSelections = [.archivedWorktrees]
        } else {
          nextSelections.remove(.archivedWorktrees)
          if let selectedWorktreeID = state.selectedWorktreeID {
            nextSelections.insert(.worktree(selectedWorktreeID))
          }
        }
        return nextSelections
      },
      set: { newValue in
        var nextSelections = newValue
        let repositorySelections: [Repository.ID] = nextSelections.compactMap { selection in
          guard case .repository(let repositoryID) = selection else { return nil }
          return repositoryID
        }
        if !repositorySelections.isEmpty {
          withAnimation(.easeOut(duration: 0.2)) {
            for repositoryID in repositorySelections {
              guard let repository = store.state.repositories[id: repositoryID],
                !store.state.isRemovingRepository(repository)
              else {
                continue
              }
              if expandedRepoIDs.contains(repositoryID) {
                expandedRepoIDs.remove(repositoryID)
              } else {
                expandedRepoIDs.insert(repositoryID)
              }
            }
          }
          nextSelections = Set(
            nextSelections.filter {
              if case .repository = $0 {
                return false
              }
              return true
            })
        }

        if nextSelections.contains(.archivedWorktrees) {
          sidebarSelections = [.archivedWorktrees]
          store.send(.selectArchivedWorktrees)
          return
        }

        let worktreeIDs = Set(nextSelections.compactMap(\.worktreeID))
        guard !worktreeIDs.isEmpty else {
          if !repositorySelections.isEmpty {
            return
          }
          sidebarSelections = []
          store.send(.selectWorktree(nil))
          return
        }
        sidebarSelections = Set(worktreeIDs.map(SidebarSelection.worktree))
        if let selectedWorktreeID = state.selectedWorktreeID, worktreeIDs.contains(selectedWorktreeID) {
          return
        }
        let nextPrimarySelection =
          hotkeyRows.map(\.id).first(where: worktreeIDs.contains)
          ?? worktreeIDs.first
        store.send(.selectWorktree(nextPrimarySelection, focusTerminal: true))
      }
    )
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
            selectedWorktreeIDs: selectedWorktreeIDs,
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
            let name = Repository.name(for: rootURL.standardizedFileURL, configuredName: nil)
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
              selectedWorktreeIDs: selectedWorktreeIDs,
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
    .scrollIndicators(.never)
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
        state.sidebarSelectedWorktreeIDs.count == 1,
        state.sidebarSelectedWorktreeIDs.contains(worktreeID),
        let terminalState = terminalManager.stateIfExists(for: worktreeID)
      else { return .ignored }
      terminalState.focusAndInsertText(keyPress.characters)
      return .handled
    }
  }
}
