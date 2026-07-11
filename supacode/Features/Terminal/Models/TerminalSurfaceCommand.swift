import Foundation

/// Terminal-only commands, carried by `SurfaceClient.Command.terminal`. The
/// shared command surface stays kind-neutral; everything that only makes sense
/// for a terminal (scripts, Ghostty binding actions, scrollback search) lives
/// here, and a future surface kind adds a sibling enum + one wrapper case
/// instead of new top-level verbs.
enum TerminalSurfaceCommand: Equatable {
  case runBlockingScript(kind: BlockingScriptKind, script: String)
  case stopRunScript
  case stopScript(definitionID: UUID)
  case performBindingAction(String)
  case performBindingActionOnSurface(surfaceID: UUID, action: String)
  case startSearch
  case searchSelection
  case navigateSearchNext
  case navigateSearchPrevious
  case endSearch
}

/// Terminal-only events, carried by `SurfaceClient.Event.terminal`. Mirror of
/// `TerminalSurfaceCommand` on the event side: neutral lifecycle / projection
/// events stay top-level on `SurfaceClient.Event`.
enum TerminalSurfaceEvent: Equatable {
  case taskStatusChanged(worktreeID: Worktree.ID, status: WorktreeTaskStatus)
  case blockingScriptCompleted(
    worktreeID: Worktree.ID, kind: BlockingScriptKind, exitCode: Int?, tabId: TerminalTabID?)
  case setupScriptConsumed(worktreeID: Worktree.ID)
  /// Forwarded from the terminal manager for hook events received over the socket.
  /// `AppFeature` translates this into `agentPresence(.hookEventReceived)`.
  case agentHookEventReceived(AgentHookEvent)
  /// Flips when the "any live terminal surface anywhere" aggregate changes.
  /// Lets menu / focused-action gates read one Bool instead of iterating
  /// `sidebarItems` from a view body.
  case hasAnySurfaceChanged(hasAny: Bool)
}
