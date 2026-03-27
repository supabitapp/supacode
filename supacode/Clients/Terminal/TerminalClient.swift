import ComposableArchitecture
import Foundation

struct TerminalClient {
  var send: @MainActor @Sendable (Command) -> Void
  var events: @MainActor @Sendable () -> AsyncStream<Event>

  enum Command: Equatable {
    case createTab(Worktree, runSetupScriptIfNew: Bool)
    case createTabWithInput(Worktree, input: String, runSetupScriptIfNew: Bool)
    case ensureInitialTab(Worktree, runSetupScriptIfNew: Bool, focusing: Bool)
    case runScript(Worktree, script: String)
    case stopRunScript(Worktree)
    case runBlockingScript(Worktree, kind: BlockingScriptKind, script: String)
    case closeFocusedTab(Worktree)
    case closeFocusedSurface(Worktree)
    case performBindingAction(Worktree, action: String)
    case startSearch(Worktree)
    case searchSelection(Worktree)
    case navigateSearchNext(Worktree)
    case navigateSearchPrevious(Worktree)
    case endSearch(Worktree)
    case prune(Set<Worktree.ID>)
    case setNotificationsEnabled(Bool)
    case setSelectedWorktreeID(Worktree.ID?)
  }

  enum Event: Equatable {
    case notificationReceived(worktreeID: Worktree.ID, title: String, body: String)
    case notificationIndicatorChanged(count: Int)
    case tabCreated(worktreeID: Worktree.ID)
    case tabClosed(worktreeID: Worktree.ID)
    case focusChanged(worktreeID: Worktree.ID, surfaceID: UUID)
    case taskStatusChanged(worktreeID: Worktree.ID, status: WorktreeTaskStatus)
    case runScriptStatusChanged(worktreeID: Worktree.ID, isRunning: Bool)
    case blockingScriptCompleted(worktreeID: Worktree.ID, kind: BlockingScriptKind, exitCode: Int?)
    case commandPaletteToggleRequested(worktreeID: Worktree.ID)
    case setupScriptConsumed(worktreeID: Worktree.ID)
  }
}

extension TerminalClient: DependencyKey {
  static let liveValue = TerminalClient(
    send: { _ in fatalError("TerminalClient.send not configured") },
    events: { fatalError("TerminalClient.events not configured") }
  )

  static let testValue = TerminalClient(
    send: { _ in },
    events: { AsyncStream { $0.finish() } }
  )
}

extension DependencyValues {
  var terminalClient: TerminalClient {
    get { self[TerminalClient.self] }
    set { self[TerminalClient.self] = newValue }
  }
}
