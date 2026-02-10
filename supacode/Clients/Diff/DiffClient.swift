import ComposableArchitecture
import Foundation

struct DiffClient {
  var send: @MainActor @Sendable (Command) -> Void
  var events: @MainActor @Sendable () -> AsyncStream<Event>

  enum Command: Equatable {
    case setWorktrees([Worktree])
    case setSelectedWorktreeID(Worktree.ID?)
    case setPanelVisible(Bool)
    case prune(Set<Worktree.ID>)
  }

  enum Event: Equatable {
    case entriesChanged(worktreeID: Worktree.ID, entries: [GitDiffEntry])
    case loadingChanged(worktreeID: Worktree.ID, isLoading: Bool)
  }
}

extension DiffClient: DependencyKey {
  static let liveValue = DiffClient(
    send: { _ in fatalError("DiffClient.send not configured") },
    events: { fatalError("DiffClient.events not configured") }
  )

  static let testValue = DiffClient(
    send: { _ in },
    events: { AsyncStream { $0.finish() } }
  )
}

extension DependencyValues {
  var diffClient: DiffClient {
    get { self[DiffClient.self] }
    set { self[DiffClient.self] = newValue }
  }
}
