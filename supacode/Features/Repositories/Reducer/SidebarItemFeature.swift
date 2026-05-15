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
    }

    var addedLines: Int?
    var removedLines: Int?
    var pullRequest: GithubPullRequest?
    /// Branch name at PR-query start; on result land, mismatched results are dropped.
    /// Invariant: non-nil iff a PR query is in flight; reset when `branchName` flips via `rosterChanged`.
    var pullRequestBranchAtQueryTime: String?

    /// Computed so `State` stays `Equatable` without conforming `WorktreePullRequestDisplay`.
    var pullRequestDisplay: WorktreePullRequestDisplay {
      WorktreePullRequestDisplay(worktreeName: branchName, pullRequest: pullRequest)
    }

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
    // MARK: - Data deltas.
    case rosterChanged(RosterDelta)
    case lifecycleChanged(State.Lifecycle)
    case diffStatsChanged(added: Int?, removed: Int?)
    case pullRequestQueryStarted(branch: String)
    case pullRequestChanged(GithubPullRequest?, branchAtQueryTime: String)
    case runningScriptStarted(id: UUID, tint: RepositoryColor)
    case runningScriptStopped(id: UUID)
    case runningScriptsCleared
    case agentSnapshotChanged([AgentPresenceFeature.AgentInstance], hasActivity: Bool)
    case terminalProjectionChanged(WorktreeRowProjection)
    case shortcutHintChanged(String?)
    case dragSessionChanged(isDragging: Bool)
    case focusTerminalRequested
    case focusTerminalConsumed

    // MARK: - User intents.
    case openRequested(OpenWorktreeAction)
    case pinToggled
    case archiveRequested
    case unarchiveRequested
    case deleteRequested
    case copyPathTapped
    case copyBranchTapped
    case openInEditorRequested
    case openInFinderRequested
    case focusNotificationRequested(notificationID: UUID, surfaceID: UUID)
    case markNotificationsReadRequested(surfaceID: UUID)
    case selected

    case delegate(Delegate)

    enum Delegate: Equatable, Sendable {
      case open(SidebarItemID, OpenWorktreeAction)
      case togglePin(SidebarItemID)
      case archive(SidebarItemID)
      case unarchive(SidebarItemID)
      case delete(SidebarItemID)
      case selected(SidebarItemID)
      case focusSurface(SidebarItemID, surfaceID: UUID)
      case markNotificationRead(SidebarItemID, notificationID: UUID)
      case markNotificationsRead(SidebarItemID, surfaceID: UUID)
      case copyToPasteboard(String)
    }
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .rosterChanged(let delta):
        Self.apply(delta, to: &state)
        return .none

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

      case .runningScriptsCleared:
        guard !state.runningScripts.isEmpty else { return .none }
        state.runningScripts.removeAll()
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

      case .openRequested(let action):
        return .send(.delegate(.open(state.id, action)))

      case .pinToggled:
        return .send(.delegate(.togglePin(state.id)))

      case .archiveRequested:
        return .send(.delegate(.archive(state.id)))

      case .unarchiveRequested:
        return .send(.delegate(.unarchive(state.id)))

      case .deleteRequested:
        return .send(.delegate(.delete(state.id)))

      case .selected:
        return .send(.delegate(.selected(state.id)))

      case .copyPathTapped:
        return .send(.delegate(.copyToPasteboard(state.workingDirectory.path(percentEncoded: false))))

      case .copyBranchTapped:
        return .send(.delegate(.copyToPasteboard(state.branchName)))

      case .openInEditorRequested:
        return .send(.delegate(.open(state.id, .editor)))

      case .openInFinderRequested:
        return .send(.delegate(.open(state.id, .finder)))

      case .focusNotificationRequested(let notificationID, let surfaceID):
        return .merge(
          .send(.delegate(.focusSurface(state.id, surfaceID: surfaceID))),
          .send(.delegate(.markNotificationRead(state.id, notificationID: notificationID)))
        )

      case .markNotificationsReadRequested(let surfaceID):
        return .send(.delegate(.markNotificationsRead(state.id, surfaceID: surfaceID)))

      case .delegate:
        return .none
      }
    }
  }

  private static func apply(_ delta: RosterDelta, to state: inout State) {
    if let name = delta.name, state.name != name { state.name = name }
    if let branchName = delta.branchName, state.branchName != branchName {
      state.branchName = branchName
      // Watermark is bound to the prior branch; clear so a future query can re-arm cleanly.
      state.pullRequestBranchAtQueryTime = nil
    }
    if let subtitle = delta.subtitle, state.subtitle != subtitle { state.subtitle = subtitle }
    if let workingDirectory = delta.workingDirectory, state.workingDirectory != workingDirectory {
      state.workingDirectory = workingDirectory
    }
    if let accent = delta.accent, state.repositoryAccent != accent { state.repositoryAccent = accent }
    if let isMainWorktree = delta.isMainWorktree, state.isMainWorktree != isMainWorktree {
      state.isMainWorktree = isMainWorktree
    }
    if let isPinned = delta.isPinned, state.isPinned != isPinned { state.isPinned = isPinned }
    if let hasMergedBadge = delta.hasMergedBadge, state.hasMergedBadge != hasMergedBadge {
      state.hasMergedBadge = hasMergedBadge
    }
  }
}

extension SidebarItemFeature.State {
  var isFolder: Bool { kind == .folder }
  var isPending: Bool { lifecycle == .pending }
  var isArchiving: Bool { lifecycle == .archiving }
  var isDeleting: Bool { lifecycle == .deleting || lifecycle == .deletingScript }
  var isLifecycleBusy: Bool { lifecycle != .idle }
  var sidebarDisplayName: String? {
    guard !isMainWorktree else { return nil }
    let last = workingDirectory.lastPathComponent
    return last.isEmpty ? nil : last
  }
  var accent: WorktreeAccent {
    if isMainWorktree { return .main }
    if isPinned { return .pinned }
    return .default
  }
}

/// Partial-update payload; `nil` field means "no update".
struct RosterDelta: Equatable, Sendable {
  var name: String?
  var branchName: String?
  /// Tri-state: outer `nil` = no update, `.some(nil)` = clear, `.some(.some(s))` = set.
  var subtitle: String??
  var workingDirectory: URL?
  /// Tri-state: outer `nil` = no update, `.some(nil)` = clear, `.some(.some(c))` = set.
  var accent: RepositoryColor??
  var isMainWorktree: Bool?
  var isPinned: Bool?
  var hasMergedBadge: Bool?
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
