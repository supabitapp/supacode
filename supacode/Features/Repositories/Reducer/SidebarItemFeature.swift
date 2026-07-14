import ComposableArchitecture
import Foundation
import SupacodeSettingsShared
import SwiftUI

enum WorktreeAccent: Hashable, Sendable {
  case `default`
  case main
  case pinned

  static func derive(isMainWorktree: Bool, isPinned: Bool) -> WorktreeAccent {
    if isMainWorktree { return .main }
    if isPinned { return .pinned }
    return .default
  }

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
    /// Mirror of `Worktree.isMissing`; drives the orphan row UI.
    var isMissing: Bool = false
    /// Mirror of `Worktree.host`: `nil` for a local item, otherwise the SSH host
    /// (carrying `<user>@<host>:<port>` via `sshDestination`). Together with
    /// `kind` this is the unified local/remote + git/folder discriminator every
    /// consumer branches on (icon, scripts, worktree creation, settings).
    var host: RemoteHost?

    /// Whether this item lives on a remote SSH host.
    var isRemote: Bool { host != nil }
    /// Mirror of `SidebarState.Item.title`; reconcile fans this in from
    /// `@Shared(.sidebar)`. `nil` or whitespace-only means fall back to `name`.
    var customTitle: String?
    /// Mirror of `SidebarState.Item.color`; reconcile fans this in from
    /// `@Shared(.sidebar)`. `nil` means default styling.
    var customTint: RepositoryColor?

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

    var agentSnapshot: AgentPresenceFeature.RowSnapshot = .init()
    var agents: [AgentPresenceFeature.AgentInstance] { agentSnapshot.agents }
    var hasAgentActivity: Bool { agentSnapshot.isWorking }
    /// An agent on this row stopped on an error. Sticky until it restarts or the
    /// user focuses the surface, and the top-priority Active-rail bucket.
    var hasAgentError: Bool { agentSnapshot.hasError }

    var surfaceIDs: [UUID] = []
    /// Sticky once `terminalProjectionChanged` arrives, so a subsequent
    /// `surfaceIDs == []` (user closed every tab) doesn't re-seed dead UUIDs
    /// from the last-quit layout snapshot.
    var hasTerminalProjection: Bool = false
    /// Ghostty progress busy on any surface. Combined with `hasAgentActivity` for shimmer.
    var isProgressBusy: Bool = false
    var hasUnseenNotifications: Bool = false
    var notifications: IdentifiedArrayOf<WorktreeTerminalNotification> = []
    /// True when either Ghostty progress is busy or an agent is busy on a surface.
    var isTaskRunning: Bool { isProgressBusy || hasAgentActivity }

    var isDragging: Bool = false
    /// One-shot focus token: set when a selection arrives with `focusTerminal: true`.
    var shouldFocusTerminal: Bool = false
  }

  enum Action: Equatable, Sendable {
    case lifecycleChanged(State.Lifecycle)
    case diffStatsChanged(added: Int?, removed: Int?)
    case pullRequestQueryStarted(branch: String)
    case pullRequestChanged(GithubPullRequest?, branchAtQueryTime: String)
    case agentSnapshotChanged(AgentPresenceFeature.RowSnapshot)
    case terminalProjectionChanged(WorktreeRowProjection)
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

      case .agentSnapshotChanged(let snapshot):
        guard state.agentSnapshot != snapshot else { return .none }
        state.agentSnapshot = snapshot
        return .none

      case .terminalProjectionChanged(let projection):
        if !state.hasTerminalProjection { state.hasTerminalProjection = true }
        if state.surfaceIDs != projection.surfaceIDs { state.surfaceIDs = projection.surfaceIDs }
        if state.isProgressBusy != projection.isProgressBusy {
          state.isProgressBusy = projection.isProgressBusy
        }
        if state.hasUnseenNotifications != projection.hasUnseenNotifications {
          state.hasUnseenNotifications = projection.hasUnseenNotifications
        }
        if state.notifications != projection.notifications { state.notifications = projection.notifications }
        if state.runningScripts != projection.runningScripts {
          state.runningScripts = projection.runningScripts
        }
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
    SidebarDisplayName.compute(
      isMainWorktree: isMainWorktree, id: id, subtitle: subtitle, branchName: branchName,
    )
  }
  /// Final string the row should render: user override (trimmed) when set,
  /// else `sidebarDisplayName`. Centralised so sidebar / archive / detail
  /// views stay in lock-step on the empty / whitespace fallback rule.
  var resolvedSidebarTitle: String? {
    SidebarDisplayName.resolved(custom: customTitle, fallback: sidebarDisplayName)
  }
  var accent: WorktreeAccent { WorktreeAccent.derive(isMainWorktree: isMainWorktree, isPinned: isPinned) }
  /// True iff any tracked agent on this row is awaiting user input.
  /// Drives the Active section's classification ("agent awaiting input").
  var hasAgentAwaitingInput: Bool { agents.contains(where: \.awaitingInput) }
}

/// Shared cascade used by both `SidebarItemFeature.State` (row) and
/// `SelectedWorktreeSlice` (cached projection). Centralising here keeps the
/// row and the detail title in lock-step; an edge case fix lands once.
enum SidebarDisplayName {
  static func compute(
    isMainWorktree: Bool,
    id: SidebarItemID,
    subtitle: String?,
    branchName: String,
  ) -> String? {
    guard !isMainWorktree else { return nil }
    if id.rawValue.contains("/") {
      let pathName = URL(fileURLWithPath: id.rawValue).lastPathComponent
      if !pathName.isEmpty { return pathName }
    }
    if let subtitle, !subtitle.isEmpty, subtitle != "." {
      let detailName = URL(fileURLWithPath: subtitle).lastPathComponent
      if !detailName.isEmpty, detailName != "." { return detailName }
    }
    return branchName
  }

  /// Returns `custom` when set (after trim), otherwise `fallback`. Shared so
  /// the sidebar, archive, and detail views can't drift on the empty /
  /// whitespace fallback rule for user-overridden titles.
  static func resolved(custom: String?, fallback: String?) -> String? {
    let trimmed = custom?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let trimmed, !trimmed.isEmpty { return trimmed }
    return fallback
  }
}

extension SidebarItemFeature.State.Lifecycle {
  var isBusy: Bool { self != .idle }
  var isPending: Bool { self == .pending }
  var isArchiving: Bool { self == .archiving }
  var isDeleting: Bool { self == .deleting || self == .deletingScript }
}

/// Per-row terminal snapshot; the manager emits it Equatable-diffed, so
/// identical snapshots never reach TCA. `isProgressBusy` reflects Ghostty
/// progress state only; the parent overlays agent activity downstream.
struct WorktreeRowProjection: Equatable, Sendable {
  let surfaceIDs: [UUID]
  let isProgressBusy: Bool
  let hasUnseenNotifications: Bool
  let notifications: IdentifiedArrayOf<WorktreeTerminalNotification>
  /// Terminal-tracked user scripts; the sole populator of the row's
  /// `runningScripts`, so the dropdown can't drift from process state (#573).
  var runningScripts: IdentifiedArrayOf<SidebarItemFeature.State.RunningScript> = []
}

/// Value-typed projection of the focused row's display fields, cached on
/// `RepositoriesFeature.State.selectedWorktreeSlice`. Excludes `agents` /
/// `hasAgentActivity` / `surfaceIDs` / `notifications` so per-leaf storms on
/// the focused row don't invalidate the detail body's observation surface.
struct SelectedWorktreeSlice: Equatable, Sendable {
  let id: SidebarItemID
  let repositoryID: Repository.ID
  let kind: SidebarItemFeature.State.Kind
  let name: String
  let branchName: String
  let subtitle: String?
  let isMainWorktree: Bool
  let isPinned: Bool
  let customTitle: String?
  let customTint: RepositoryColor?
  let lifecycle: SidebarItemFeature.State.Lifecycle
  let pullRequest: GithubPullRequest?
  let runningScripts: IdentifiedArrayOf<SidebarItemFeature.State.RunningScript>

  init(_ row: SidebarItemFeature.State) {
    self.id = row.id
    self.repositoryID = row.repositoryID
    self.kind = row.kind
    self.name = row.name
    self.branchName = row.branchName
    self.subtitle = row.subtitle
    self.isMainWorktree = row.isMainWorktree
    self.isPinned = row.isPinned
    self.customTitle = row.customTitle
    self.customTint = row.customTint
    self.lifecycle = row.lifecycle
    self.pullRequest = row.pullRequest
    self.runningScripts = row.runningScripts
  }

  var sidebarDisplayName: String? {
    SidebarDisplayName.compute(
      isMainWorktree: isMainWorktree, id: id, subtitle: subtitle, branchName: branchName,
    )
  }

  var resolvedSidebarTitle: String? {
    SidebarDisplayName.resolved(custom: customTitle, fallback: sidebarDisplayName)
  }

  var accent: WorktreeAccent { WorktreeAccent.derive(isMainWorktree: isMainWorktree, isPinned: isPinned) }

  var isFolder: Bool { kind == .folder }
}
