import ComposableArchitecture
import Foundation
import SupacodeSettingsShared
import SwiftUI

enum WorktreeAccent: Hashable, Sendable {
  case `default`
  case main
  case pinned

  func shapeStyle(emphasized: Bool) -> AnyShapeStyle {
    guard !emphasized else { return AnyShapeStyle(.secondary) }
    return switch self {
    case .main: AnyShapeStyle(.yellow)
    case .pinned: AnyShapeStyle(.orange)
    case .default: AnyShapeStyle(.tertiary)
    }
  }
}

/// Per-row sidebar feature. The view body reads exclusively from this state;
/// the parent dispatches per-row deltas to keep it in sync.
@Reducer
struct SidebarItemFeature {
  @ObservableState
  struct State: Identifiable, Equatable, Sendable {
    let id: SidebarItemID
    let repositoryID: Repository.ID
    let kind: Kind

    enum Kind: Equatable, Sendable {
      case gitWorktree
      case folder
    }

    var name: String
    var branchName: String
    var subtitle: String?
    var workingDirectory: URL
    var repositoryAccent: RepositoryColor?
    var isMainWorktree: Bool
    /// Mirror of `@Shared(.sidebar)`; written through actions only.
    var isPinned: Bool
    var hasMergedBadge: Bool

    var lifecycle: Lifecycle = .idle

    enum Lifecycle: Equatable, Sendable {
      case idle
      /// Either git create-worktree in flight or setup-script pending.
      case pending
      case archiving
      case deletingScript
      case deleting

      /// True for the wind-down states that should drop out of the Active
      /// rail. `.pending` stays eligible: a row running its setup script is
      /// exactly what Active is meant to surface.
      var isTerminating: Bool {
        switch self {
        case .archiving, .deletingScript, .deleting: return true
        case .idle, .pending: return false
        }
      }
    }

    var addedLines: Int?
    var removedLines: Int?
    var pullRequest: GithubPullRequest?
    /// Branch name at PR-query start; on result land, mismatched results are dropped.
    /// Invariant: non-nil iff a PR query is in flight; cleared by reconcile on branch rename.
    var pullRequestBranchAtQueryTime: String?

    var runningScripts: IdentifiedArrayOf<RunningScript> = []

    struct RunningScript: Equatable, Identifiable, Sendable {
      /// Matches `ScriptDefinition.id`.
      let id: UUID
      var tint: RepositoryColor
    }

    var agents: [AgentPresenceFeature.AgentInstance] = []
    var hasAgentActivity: Bool = false

    var surfaceIDs: [UUID] = []
    /// Ghostty progress busy on any surface. Combined with `hasAgentActivity` for shimmer.
    var isProgressBusy: Bool = false
    var hasUnseenNotifications: Bool = false
    var notifications: IdentifiedArrayOf<WorktreeTerminalNotification> = []
    /// True when either Ghostty progress is busy or an agent is busy on a surface.
    var isTaskRunning: Bool { isProgressBusy || hasAgentActivity }

    var isDragging: Bool = false
    var shortcutHint: String?
    /// One-shot focus token: set when a selection arrives with `focusTerminal: true`.
    var shouldFocusTerminal: Bool = false
  }

  enum Action: Equatable, Sendable {
    case lifecycleChanged(State.Lifecycle)
    case diffStatsChanged(added: Int?, removed: Int?)
    case pullRequestQueryStarted(branch: String)
    case pullRequestChanged(GithubPullRequest?, branchAtQueryTime: String)
    case runningScriptStarted(id: UUID, tint: RepositoryColor)
    case runningScriptStopped(id: UUID)
    case agentSnapshotChanged([AgentPresenceFeature.AgentInstance], hasActivity: Bool)
    case terminalProjectionChanged(WorktreeRowProjection)
    case shortcutHintChanged(String?)
    case dragSessionChanged(isDragging: Bool)
    case focusTerminalRequested
    case focusTerminalConsumed
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .lifecycleChanged(let next):
        guard state.lifecycle != next else { return .none }
        state.lifecycle = next
        return .none

      case .diffStatsChanged(let added, let removed):
        guard state.addedLines != added || state.removedLines != removed else { return .none }
        state.addedLines = added
        state.removedLines = removed
        return .none

      case .pullRequestQueryStarted(let branch):
        guard state.pullRequestBranchAtQueryTime != branch else { return .none }
        state.pullRequestBranchAtQueryTime = branch
        return .none

      case .pullRequestChanged(let pullRequest, let branchAtQueryTime):
        // Drop late results for a branch the row no longer represents.
        guard branchAtQueryTime == state.branchName else { return .none }
        guard state.pullRequest != pullRequest else {
          if state.pullRequestBranchAtQueryTime != nil {
            state.pullRequestBranchAtQueryTime = nil
          }
          return .none
        }
        state.pullRequest = pullRequest
        state.pullRequestBranchAtQueryTime = nil
        return .none

      case .runningScriptStarted(let id, let tint):
        if state.runningScripts[id: id] == nil {
          state.runningScripts.append(.init(id: id, tint: tint))
        } else if state.runningScripts[id: id]?.tint != tint {
          state.runningScripts[id: id]?.tint = tint
        }
        return .none

      case .runningScriptStopped(let id):
        guard state.runningScripts.contains(where: { $0.id == id }) else { return .none }
        state.runningScripts.remove(id: id)
        return .none

      case .agentSnapshotChanged(let agents, let hasActivity):
        guard state.agents != agents || state.hasAgentActivity != hasActivity else { return .none }
        state.agents = agents
        state.hasAgentActivity = hasActivity
        return .none

      case .terminalProjectionChanged(let projection):
        if state.surfaceIDs != projection.surfaceIDs { state.surfaceIDs = projection.surfaceIDs }
        if state.isProgressBusy != projection.isProgressBusy {
          state.isProgressBusy = projection.isProgressBusy
        }
        if state.hasUnseenNotifications != projection.hasUnseenNotifications {
          state.hasUnseenNotifications = projection.hasUnseenNotifications
        }
        if state.notifications != projection.notifications { state.notifications = projection.notifications }
        return .none

      case .shortcutHintChanged(let hint):
        guard state.shortcutHint != hint else { return .none }
        state.shortcutHint = hint
        return .none

      case .dragSessionChanged(let isDragging):
        guard state.isDragging != isDragging else { return .none }
        state.isDragging = isDragging
        return .none

      case .focusTerminalRequested:
        guard !state.shouldFocusTerminal else { return .none }
        state.shouldFocusTerminal = true
        return .none

      case .focusTerminalConsumed:
        guard state.shouldFocusTerminal else { return .none }
        state.shouldFocusTerminal = false
        return .none
      }
    }
  }
}

extension SidebarItemFeature.State {
  var isFolder: Bool { kind == .folder }
  /// Cascade: nil for main worktrees, then the row id's last path component,
  /// then the subtitle's last path component, then `branchName`.
  var sidebarDisplayName: String? {
    guard !isMainWorktree else { return nil }
    if id.contains("/") {
      let pathName = URL(fileURLWithPath: id).lastPathComponent
      if !pathName.isEmpty { return pathName }
    }
    if let subtitle, !subtitle.isEmpty, subtitle != "." {
      let detailName = URL(fileURLWithPath: subtitle).lastPathComponent
      if !detailName.isEmpty, detailName != "." { return detailName }
    }
    return branchName
  }
  var accent: WorktreeAccent {
    if isMainWorktree { return .main }
    if isPinned { return .pinned }
    return .default
  }
  /// True iff any tracked agent on this row is awaiting user input.
  /// Drives the Active section's classification ("agent awaiting input").
  var hasAgentAwaitingInput: Bool { agents.contains(where: \.awaitingInput) }
}

extension SidebarItemFeature.State.Lifecycle {
  var isBusy: Bool { self != .idle }
  var isPending: Bool { self == .pending }
  var isArchiving: Bool { self == .archiving }
  var isDeleting: Bool { self == .deleting || self == .deletingScript }
}

/// Per-row terminal snapshot emitted by `WorktreeTerminalManager`'s 400 ms debounce.
/// `isProgressBusy` reflects Ghostty progress state only; the parent overlays
/// agent activity downstream of this event.
struct WorktreeRowProjection: Equatable, Sendable {
  let surfaceIDs: [UUID]
  let isProgressBusy: Bool
  let hasUnseenNotifications: Bool
  let notifications: IdentifiedArrayOf<WorktreeTerminalNotification>
}
