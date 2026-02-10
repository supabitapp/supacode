import ComposableArchitecture
import Foundation

@Reducer
struct WorktreeDiffFeature {
  struct ActiveWorktree: Equatable, Sendable {
    let id: Worktree.ID
    let rootURL: URL
  }

  struct WorktreeState: Equatable, Sendable {
    var rootURL: URL
    var entries: [GitDiffEntry] = []
    var isLoadingEntries = false
    var entriesError: String?
    var selectedPath: String?
    var diff = DiffState()
    var diffRequestID = 0

    static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.rootURL == rhs.rootURL
        && lhs.entries == rhs.entries
        && lhs.isLoadingEntries == rhs.isLoadingEntries
        && lhs.entriesError == rhs.entriesError
        && lhs.selectedPath == rhs.selectedPath
        && lhs.diff == rhs.diff
        && lhs.diffRequestID == rhs.diffRequestID
    }
  }

  struct DiffState: Equatable, Sendable {
    var isLoading = false
    var error: String?
    var document = DiffDocument()

    static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.isLoading == rhs.isLoading
        && lhs.error == rhs.error
        && lhs.document == rhs.document
    }
  }

  struct DiffDocument: Equatable, Sendable {
    var revision = 0
    var text: String = ""

    static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.revision == rhs.revision
    }
  }

  @ObservableState
  struct State: Equatable {
    var isPresented = false
    var activeWorktree: ActiveWorktree?
    var worktrees: [Worktree.ID: WorktreeState] = [:]
  }

  enum Action {
    case setPresented(Bool)
    case setActiveWorktree(ActiveWorktree?)
    case refreshActiveWorktree
    case entriesResponse(Worktree.ID, Result<[GitDiffEntry], any Error>)
    case setSelectedPath(Worktree.ID, String?)
    case diffResponse(Worktree.ID, requestID: Int, Result<String, any Error>)
    case pollTick
    case pruneWorktrees(Set<Worktree.ID>)
  }

  @Dependency(\.continuousClock) private var clock
  @Dependency(\.gitDiffClient) private var gitDiffClient

  private enum CancelID {
    static let polling = "worktreeDiff.polling"
    static func entries(_ worktreeID: Worktree.ID) -> String { "worktreeDiff.entries.\(worktreeID)" }
    static func diff(_ worktreeID: Worktree.ID) -> String { "worktreeDiff.diff.\(worktreeID)" }
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .setPresented(let isPresented):
        state.isPresented = isPresented
        guard isPresented else {
          if let activeID = state.activeWorktree?.id {
            return .merge(
              .cancel(id: CancelID.polling),
              .cancel(id: CancelID.entries(activeID)),
              .cancel(id: CancelID.diff(activeID))
            )
          }
          return .cancel(id: CancelID.polling)
        }

        let polling = Effect<Action>.run { send in
          while !Task.isCancelled {
            try await clock.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await send(.pollTick)
          }
        }
        .cancellable(id: CancelID.polling, cancelInFlight: true)

        if state.activeWorktree == nil {
          return polling
        }
        return .merge(
          .send(.refreshActiveWorktree),
          polling
        )

      case .setActiveWorktree(let activeWorktree):
        let previousActiveID = state.activeWorktree?.id
        state.activeWorktree = activeWorktree
        guard let activeWorktree else {
          state.isPresented = false
          if let previousActiveID {
            return .merge(
              .cancel(id: CancelID.polling),
              .cancel(id: CancelID.entries(previousActiveID)),
              .cancel(id: CancelID.diff(previousActiveID))
            )
          }
          return .cancel(id: CancelID.polling)
        }

        state.worktrees[activeWorktree.id, default: .init(rootURL: activeWorktree.rootURL)].rootURL =
          activeWorktree.rootURL
        if state.isPresented {
          if let previousActiveID, previousActiveID != activeWorktree.id {
            return .merge(
              .cancel(id: CancelID.entries(previousActiveID)),
              .cancel(id: CancelID.diff(previousActiveID)),
              .send(.refreshActiveWorktree)
            )
          }
          return .send(.refreshActiveWorktree)
        }
        return .none

      case .pollTick:
        guard state.isPresented, state.activeWorktree != nil else {
          return .none
        }
        return .send(.refreshActiveWorktree)

      case .refreshActiveWorktree:
        guard let active = state.activeWorktree else {
          return .none
        }
        state.worktrees[active.id, default: .init(rootURL: active.rootURL)].isLoadingEntries = true
        state.worktrees[active.id]?.entriesError = nil

        return .run { send in
          do {
            let entries = try await gitDiffClient.statusEntries(active.rootURL)
            await send(.entriesResponse(active.id, .success(entries)))
          } catch {
            await send(.entriesResponse(active.id, .failure(error)))
          }
        }
        .cancellable(id: CancelID.entries(active.id), cancelInFlight: true)

      case .entriesResponse(let worktreeID, let result):
        guard var worktreeState = state.worktrees[worktreeID] else {
          return .none
        }
        worktreeState.isLoadingEntries = false
        switch result {
        case .success(let entries):
          worktreeState.entries = entries
          worktreeState.entriesError = nil
          if let selectedPath = worktreeState.selectedPath,
            !entries.contains(where: { $0.path == selectedPath })
          {
            worktreeState.selectedPath = nil
            worktreeState.diff = .init()
            worktreeState.diffRequestID = 0
          }
        case .failure(let error):
          worktreeState.entries = []
          worktreeState.entriesError = error.localizedDescription
        }
        state.worktrees[worktreeID] = worktreeState
        return .none

      case .setSelectedPath(let worktreeID, let selectedPath):
        guard var worktreeState = state.worktrees[worktreeID] else {
          return .none
        }
        worktreeState.selectedPath = selectedPath
        worktreeState.diffRequestID += 1
        let requestID = worktreeState.diffRequestID

        guard let selectedPath else {
          worktreeState.diff = .init()
          state.worktrees[worktreeID] = worktreeState
          return .cancel(id: CancelID.diff(worktreeID))
        }

        guard let entry = worktreeState.entries.first(where: { $0.path == selectedPath }) else {
          worktreeState.diff = .init()
          state.worktrees[worktreeID] = worktreeState
          return .none
        }

        worktreeState.diff.isLoading = true
        worktreeState.diff.error = nil
        worktreeState.diff.document = .init(revision: requestID * 2 - 1, text: "")
        state.worktrees[worktreeID] = worktreeState

        let worktreeRoot = worktreeState.rootURL
        return .run { send in
          do {
            let text = try await gitDiffClient.diffText(worktreeRoot, entry)
            await send(.diffResponse(worktreeID, requestID: requestID, .success(text)))
          } catch {
            await send(.diffResponse(worktreeID, requestID: requestID, .failure(error)))
          }
        }
        .cancellable(id: CancelID.diff(worktreeID), cancelInFlight: true)

      case .diffResponse(let worktreeID, let requestID, let result):
        guard var worktreeState = state.worktrees[worktreeID] else {
          return .none
        }
        guard worktreeState.diffRequestID == requestID else {
          return .none
        }
        worktreeState.diff.isLoading = false
        switch result {
        case .success(let text):
          worktreeState.diff.error = nil
          worktreeState.diff.document = .init(revision: requestID * 2, text: text)
        case .failure(let error):
          worktreeState.diff.error = error.localizedDescription
          worktreeState.diff.document = .init(revision: requestID * 2, text: "")
        }
        state.worktrees[worktreeID] = worktreeState
        return .none

      case .pruneWorktrees(let validIDs):
        state.worktrees = Dictionary(uniqueKeysWithValues: state.worktrees.filter { validIDs.contains($0.key) })
        if let activeID = state.activeWorktree?.id, !validIDs.contains(activeID) {
          state.activeWorktree = nil
          state.isPresented = false
          return .merge(
            .cancel(id: CancelID.polling),
            .cancel(id: CancelID.entries(activeID)),
            .cancel(id: CancelID.diff(activeID))
          )
        }
        return .none
      }
    }
  }
}
