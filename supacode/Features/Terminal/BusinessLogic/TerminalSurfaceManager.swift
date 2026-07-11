import Foundation
import SupacodeSettingsShared

private let terminalLogger = SupaLogger("Terminal")

/// Terminal-kind command handling, owned by the terminal kind rather than the
/// neutral core: `WorktreeSurfaceManager`'s `.terminal` dispatch arm forwards
/// here and never interprets the payload. A future surface kind adds a sibling
/// manager and one dispatch arm; nothing in this file is shared.
///
/// One instance serves every worktree — commands arrive addressed by
/// `Worktree`, and per-worktree resolution must stay behind the core's
/// `state(for:)` / `stateIfExists(for:)` split so the stop arms can act on
/// existing state without minting any.
@MainActor
final class TerminalSurfaceManager {
  private unowned let core: WorktreeSurfaceManager

  init(core: WorktreeSurfaceManager) {
    self.core = core
  }

  /// Resolve state per arm, never up front: the stop arms promise not to mint
  /// state for a worktree that has none (`stopBlockingScripts` goes through
  /// `stateIfExists`), and a hoisted lookup would break that promise.
  func handle(_ command: TerminalSurfaceCommand, in worktree: Worktree) {
    switch command {
    case .runBlockingScript(let kind, let script):
      _ = core.state(for: worktree).runBlockingScript(kind: kind, script)
    case .stopRunScript:
      stopBlockingScripts(in: worktree) { $0.stopRunScripts() }
    case .stopScript(let definitionID):
      stopBlockingScripts(in: worktree) { $0.stopScript(definitionID: definitionID) }
    case .performBindingAction(let action):
      core.state(for: worktree).performBindingActionOnFocusedSurface(action)
    case .performBindingActionOnSurface(let surfaceID, let action):
      core.state(for: worktree).performBindingAction(action, onSurfaceID: surfaceID)
    case .startSearch:
      core.state(for: worktree).performBindingActionOnFocusedSurface("start_search")
    case .searchSelection:
      core.state(for: worktree).performBindingActionOnFocusedSurface("search_selection")
    case .navigateSearchNext:
      core.state(for: worktree).navigateSearchOnFocusedSurface(.next)
    case .navigateSearchPrevious:
      core.state(for: worktree).navigateSearchOnFocusedSurface(.previous)
    case .endSearch:
      core.state(for: worktree).performBindingActionOnFocusedSurface("end_search")
    }
  }

  /// Runs `stop` on the worktree's existing terminal state, never minting one.
  /// A miss with a live state means the caller acted on a stale mirror, so force
  /// a fresh projection emit past the dedupe cache to reconcile it (#573).
  private func stopBlockingScripts(in worktree: Worktree, using stop: (WorktreeSurfaceState) -> Bool) {
    guard let state = core.stateIfExists(for: worktree.id) else {
      terminalLogger.warning("Stop requested for \(worktree.id) with no terminal state")
      return
    }
    guard !stop(state) else { return }
    terminalLogger.warning("Stop requested for \(worktree.id) with no matching script; re-emitting projection")
    core.forceEmitProjection(for: worktree.id)
  }
}
