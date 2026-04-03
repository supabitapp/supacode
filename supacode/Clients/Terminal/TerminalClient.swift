import ComposableArchitecture
import Foundation

struct TerminalClient {
  var send: @MainActor @Sendable (Command) -> Void
  var events: @MainActor @Sendable () -> AsyncStream<Event>
  var tabExists: @MainActor @Sendable (Worktree.ID, TerminalTabID) -> Bool
  var surfaceExists: @MainActor @Sendable (Worktree.ID, TerminalTabID, UUID) -> Bool

  enum Command: Equatable {
    case createTab(Worktree, runSetupScriptIfNew: Bool, id: UUID? = nil)
    case createTabWithInput(Worktree, input: String, runSetupScriptIfNew: Bool, id: UUID? = nil)
    case ensureInitialTab(Worktree, runSetupScriptIfNew: Bool, focusing: Bool)
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
    case selectTab(Worktree, tabID: TerminalTabID)
    case focusSurface(Worktree, tabID: TerminalTabID, surfaceID: UUID, input: String? = nil)
    case splitSurface(
      Worktree, tabID: TerminalTabID, surfaceID: UUID, direction: SplitDirection,
      input: String?, id: UUID? = nil)
    case destroyTab(Worktree, tabID: TerminalTabID)
    case destroySurface(Worktree, tabID: TerminalTabID, surfaceID: UUID)
    case prune(Set<Worktree.ID>)
    case setNotificationsEnabled(Bool)
    case setSelectedWorktreeID(Worktree.ID?)
    case refreshTabBarVisibility
  }

  enum Event: Equatable {
    case notificationReceived(worktreeID: Worktree.ID, title: String, body: String)
    case notificationIndicatorChanged(count: Int)
    case tabCreated(worktreeID: Worktree.ID)
    case tabClosed(worktreeID: Worktree.ID)
    case focusChanged(worktreeID: Worktree.ID, surfaceID: UUID)
    case taskStatusChanged(worktreeID: Worktree.ID, status: WorktreeTaskStatus)
    case blockingScriptCompleted(
      worktreeID: Worktree.ID, kind: BlockingScriptKind, exitCode: Int?, tabId: TerminalTabID?)
    case commandPaletteToggleRequested(worktreeID: Worktree.ID)
    case setupScriptConsumed(worktreeID: Worktree.ID)
  }
}

extension TerminalClient: DependencyKey {
  static let liveValue = TerminalClient(
    send: { _ in fatalError("TerminalClient.send not configured") },
    events: { fatalError("TerminalClient.events not configured") },
    tabExists: { _, _ in fatalError("TerminalClient.tabExists not configured") },
    surfaceExists: { _, _, _ in fatalError("TerminalClient.surfaceExists not configured") }
  )

  static let testValue = TerminalClient(
    send: { _ in },
    events: { AsyncStream { $0.finish() } },
    tabExists: unimplemented("TerminalClient.tabExists", placeholder: true),
    surfaceExists: unimplemented("TerminalClient.surfaceExists", placeholder: true)
  )
}

extension DependencyValues {
  var terminalClient: TerminalClient {
    get { self[TerminalClient.self] }
    set { self[TerminalClient.self] = newValue }
  }
}
