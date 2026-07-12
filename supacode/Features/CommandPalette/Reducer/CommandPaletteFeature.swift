import ComposableArchitecture
import Foundation
import OrderedCollections
import Sharing
import SupacodeSettingsShared

private nonisolated let commandPaletteLogger = SupaLogger("CommandPalette")

@Reducer
struct CommandPaletteFeature {
  /// Two narrow surfaces sharing one palette UI. `.commands` is the full
  /// command palette (scripts, ghostty actions, PR actions, settings);
  /// `.worktreeSwitcher` shows only worktrees, sorted by
  /// `RepositoriesFeature.State.worktreeMRU`. Mode lives in State so the
  /// items builder, the view, and the dismiss handler all read the same
  /// source of truth.
  enum PaletteMode: Equatable, Sendable {
    case commands
    case worktreeSwitcher
  }

  @ObservableState
  struct State: Equatable {
    var isPresented = false
    var mode: PaletteMode = .commands
    var query = ""
    var selectedIndex: Int?
    var recencyByItemID: [CommandPaletteItem.ID: TimeInterval] = [:]
  }

  enum SelectionMove: Equatable {
    case upSelection
    case downSelection
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)
    case setPresented(Bool)
    case togglePresented
    /// Open the palette in a specific mode. No-op if already presented in
    /// the same mode; switches mode and refreshes selection if already
    /// presented in a different mode. Wired to the Cmd+P / Cmd+Shift+P
    /// menu items in `supacodeApp.swift`.
    case presentInMode(PaletteMode)
    case activateItem(CommandPaletteItem)
    case updateSelection(itemsCount: Int, defaultIndex: Int)
    case resetSelection(itemsCount: Int, defaultIndex: Int)
    case moveSelection(SelectionMove, itemsCount: Int)
    case pruneRecency([CommandPaletteItem.ID])
    case delegate(Delegate)
  }

  @CasePathable
  enum Delegate: Equatable {
    case selectWorktree(Worktree.ID)
    case checkForUpdates
    case openSettings
    case newWorktree
    case openRepository
    case addRemoteRepository
    case removeWorktree(Worktree.ID, Repository.ID)
    case archiveWorktree(Worktree.ID, Repository.ID)
    case renameBranch(Worktree.ID, Repository.ID)
    case viewArchivedWorktrees
    case refreshWorktrees
    case ghosttyCommand(String)
    case openPullRequest(Worktree.ID)
    case markPullRequestReady(Worktree.ID)
    case mergePullRequest(Worktree.ID)
    case closePullRequest(Worktree.ID)
    case copyFailingJobURL(Worktree.ID)
    case copyCiFailureLogs(Worktree.ID)
    case rerunFailedJobs(Worktree.ID)
    case openFailingCheckDetails(Worktree.ID)
    case runScript(ScriptDefinition)
    case stopScript(UUID, name: String)
    /// Palette closed without the user activating an item (Esc, outside
    /// tap, programmatic dismiss). AppFeature uses this to refocus the
    /// current worktree's terminal, the "terminal is the default
    /// focus" invariant.
    case dismissedWithoutSelection
    #if DEBUG
      case debugTestToast(RepositoriesFeature.StatusToast)
    #endif
  }

  @Dependency(\.date.now) private var now

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .setPresented(let isPresented):
        let wasPresented = state.isPresented
        state.isPresented = isPresented
        if isPresented {
          loadRecency(into: &state)
          state.selectedIndex = nil
        } else {
          state.resetForDismiss()
        }
        if wasPresented, !isPresented {
          return .send(.delegate(.dismissedWithoutSelection))
        }
        return .none

      case .togglePresented:
        let wasPresented = state.isPresented
        state.isPresented.toggle()
        if state.isPresented {
          state.mode = .commands
          loadRecency(into: &state)
          state.selectedIndex = nil
        } else {
          state.resetForDismiss()
        }
        if wasPresented, !state.isPresented {
          return .send(.delegate(.dismissedWithoutSelection))
        }
        return .none

      case .presentInMode(let mode):
        let wasPresented = state.isPresented
        let modeChanged = state.mode != mode
        state.isPresented = true
        state.mode = mode
        if !wasPresented || modeChanged {
          loadRecency(into: &state)
          state.query = ""
          state.selectedIndex = nil
        }
        return .none

      case .activateItem(let item):
        state.isPresented = false
        state.resetForDismiss()
        state.recencyByItemID[item.id] = now.timeIntervalSince1970
        saveRecency(state.recencyByItemID)
        // No `.dismissedWithoutSelection` here: every activation delegate
        // resolves to a destination that owns its own focus transition.
        return .send(.delegate(delegateAction(for: item.kind)))

      case .updateSelection(let itemsCount, let defaultIndex):
        if itemsCount == 0 {
          state.selectedIndex = nil
          return .none
        }
        if let selectedIndex = state.selectedIndex, selectedIndex >= itemsCount {
          state.selectedIndex = itemsCount - 1
        } else if state.selectedIndex == nil {
          state.selectedIndex = min(max(defaultIndex, 0), itemsCount - 1)
        }
        return .none

      case .resetSelection(let itemsCount, let defaultIndex):
        state.selectedIndex = itemsCount == 0 ? nil : min(max(defaultIndex, 0), itemsCount - 1)
        return .none

      case .moveSelection(let direction, let itemsCount):
        guard itemsCount > 0 else {
          state.selectedIndex = nil
          return .none
        }
        let maxIndex = itemsCount - 1
        switch direction {
        case .upSelection:
          if let selectedIndex = state.selectedIndex {
            state.selectedIndex = selectedIndex == 0 ? maxIndex : selectedIndex - 1
          } else {
            state.selectedIndex = maxIndex
          }
        case .downSelection:
          if let selectedIndex = state.selectedIndex {
            state.selectedIndex = selectedIndex == maxIndex ? 0 : selectedIndex + 1
          } else {
            state.selectedIndex = 0
          }
        }
        return .none

      case .pruneRecency(let ids):
        let idSet = Set(ids)
        let pruned = state.recencyByItemID.filter { idSet.contains($0.key) }
        guard pruned != state.recencyByItemID else { return .none }
        state.recencyByItemID = pruned
        saveRecency(pruned)
        return .none

      case .delegate:
        return .none
      }
    }
  }

  /// Where the cursor lands when there's no prior selection. Normally the top
  /// row (0). In the worktree switcher with an empty query, the current-worktree
  /// row sits at index 0, so skip to 1 (⌘P then Enter switches to the previous
  /// worktree instead of being a no-op). Once the user types, the top match wins.
  static func defaultSelectionIndex(rows: [CommandPaletteItem], query: String) -> Int {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty, rows.count > 1, rows.first?.isCurrentWorktree == true else {
      return 0
    }
    return 1
  }

  static func filterItems(
    items: [CommandPaletteItem],
    query: String,
    mode: PaletteMode = .commands,
    recencyByID: [CommandPaletteItem.ID: TimeInterval] = [:],
    now: Date = .now
  ) -> [CommandPaletteItem] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      switch mode {
      case .commands:
        // The empty-query commands palette shows only the non-root global
        // actions; scripts and PR actions surface once you type.
        let visibleItems = items.filter { $0.isGlobal && !$0.isRootAction }
        return prioritizeItems(items: visibleItems, recencyByID: recencyByID, now: now)
      case .worktreeSwitcher:
        // The switcher is a navigation surface: every worktree row is visible
        // with no query, already ordered MRU-first via `priorityTier`.
        return prioritizeItems(items: items, recencyByID: recencyByID, now: now)
      }
    }
    let scorer = CommandPaletteFuzzyScorer(query: trimmed, recencyByID: recencyByID, now: now)
    return scorer.rankedItems(from: items)
  }

  /// The always-present global actions, shown regardless of selection.
  static func globalActionItems() -> [CommandPaletteItem] {
    [
      CommandPaletteItem(
        id: CommandPaletteItemID.globalCheckForUpdates,
        title: "Check for Updates",
        subtitle: nil,
        kind: .checkForUpdates
      ),
      CommandPaletteItem(
        id: CommandPaletteItemID.globalOpenSettings,
        title: "Open Settings",
        subtitle: nil,
        kind: .openSettings
      ),
      CommandPaletteItem(
        id: CommandPaletteItemID.globalOpenRepository,
        title: "Open Repository or Folder",
        subtitle: nil,
        kind: .openRepository
      ),
      CommandPaletteItem(
        id: CommandPaletteItemID.globalAddRemoteRepository,
        title: "Add Remote Repository",
        subtitle: nil,
        kind: .addRemoteRepository
      ),
      CommandPaletteItem(
        id: CommandPaletteItemID.globalNewWorktree,
        title: "New Worktree",
        subtitle: nil,
        kind: .newWorktree
      ),
      CommandPaletteItem(
        id: CommandPaletteItemID.globalRefreshWorktrees,
        title: "Refresh Worktrees",
        subtitle: nil,
        kind: .refreshWorktrees
      ),
      CommandPaletteItem(
        id: CommandPaletteItemID.globalViewArchivedWorktrees,
        title: "View Archived Worktrees",
        subtitle: nil,
        kind: .viewArchivedWorktrees
      ),
    ]
  }

  static func commandPaletteItems(
    from repositories: RepositoriesFeature.State,
    ghosttyCommands: [GhosttyCommand] = [],
    scripts: [ScriptDefinition] = [],
    runningScriptIDs: Set<UUID> = []
  ) -> [CommandPaletteItem] {
    var items = globalActionItems()
    if repositories.selectedWorktreeID != nil {
      items.append(contentsOf: ghosttyCommandItems(ghosttyCommands))
      items.append(contentsOf: scriptItems(scripts: scripts, runningScriptIDs: runningScriptIDs))
    }
    if let selectedWorktreeID = repositories.selectedWorktreeID,
      let repositoryID = repositories.repositoryID(containing: selectedWorktreeID),
      let pullRequest = repositories.sidebarItems[id: selectedWorktreeID]?.pullRequest,
      pullRequest.number > 0,
      pullRequest.state.uppercased() != "CLOSED"
    {
      let pullRequestActions = pullRequestItems(
        pullRequest: pullRequest,
        worktreeID: selectedWorktreeID,
        repositoryID: repositoryID
      )
      items.append(contentsOf: pullRequestActions)
    }
    #if DEBUG
      items.append(contentsOf: debugToastItems())
    #endif
    if let renameBranchItem = renameBranchItem(from: repositories) {
      items.append(renameBranchItem)
    }
    // Worktree navigation is the ⌘P switcher's job (see `worktreeSwitcherItems`);
    // the ⌘⇧P command palette lists actions only, not worktree rows.
    return items
  }

  /// The "Rename Branch" action for the selected git worktree, or `nil` when the
  /// selection isn't an idle, attached, non-folder worktree that can be renamed.
  static func renameBranchItem(from repositories: RepositoriesFeature.State) -> CommandPaletteItem? {
    guard let selectedWorktreeID = repositories.selectedWorktreeID,
      let selectedRow = repositories.sidebarItems[id: selectedWorktreeID],
      let selectedRepositoryID = repositories.repositoryID(containing: selectedWorktreeID),
      let selectedWorktree = repositories.worktree(for: selectedWorktreeID),
      !selectedRow.isFolder,
      !selectedRow.name.isEmpty,
      selectedRow.lifecycle == .idle,
      selectedWorktree.isAttached,
      !selectedWorktree.isMissing
    else {
      return nil
    }
    let repositoryName = Repository.sidebarDisplayName(
      custom: repositories.sidebar.sections[selectedRepositoryID]?.title,
      fallback: repositories.repositoryName(for: selectedRepositoryID) ?? "Repository"
    )
    let worktreeDisplayName =
      SidebarDisplayName.resolved(custom: selectedRow.customTitle, fallback: selectedRow.name)
      ?? selectedRow.name
    return CommandPaletteItem(
      id: CommandPaletteItemID.renameBranch(selectedWorktreeID),
      title: "Rename Branch",
      subtitle: "\(repositoryName) · \(worktreeDisplayName)",
      kind: .renameBranch(selectedWorktreeID, selectedRepositoryID)
    )
  }

  static func recencyRetentionIDs(
    from repositories: IdentifiedArrayOf<Repository>,
    scripts: [ScriptDefinition] = []
  ) -> [CommandPaletteItem.ID] {
    var ids = CommandPaletteItemID.globalIDs
    for repository in repositories {
      ids.append(contentsOf: CommandPaletteItemID.pullRequestIDs(repositoryID: repository.id))
      for worktree in repository.worktrees {
        ids.append(CommandPaletteItemID.worktreeSelect(worktree.id))
        ids.append(CommandPaletteItemID.renameBranch(worktree.id))
      }
    }
    for script in scripts {
      ids.append(CommandPaletteItemID.runScript(script.id))
      ids.append(CommandPaletteItemID.stopScript(script.id))
    }
    return ids
  }

  /// Mode-aware item dispatch. The palette overlay calls this once per
  /// re-render; the mode comes from `State.mode` and the per-mode
  /// builders own all selection / ranking / subtitle decisions.
  static func items(
    in mode: PaletteMode,
    from repositories: RepositoriesFeature.State,
    ghosttyCommands: [GhosttyCommand] = [],
    scripts: [ScriptDefinition] = [],
    runningScriptIDs: Set<UUID> = []
  ) -> [CommandPaletteItem] {
    switch mode {
    case .commands:
      return commandPaletteItems(
        from: repositories,
        ghosttyCommands: ghosttyCommands,
        scripts: scripts,
        runningScriptIDs: runningScriptIDs
      )
    case .worktreeSwitcher:
      return worktreeSwitcherItems(from: repositories)
    }
  }

  /// Worktree switcher items. Order: `worktreeMRU` entries first in recency
  /// order (most-recent-first), then any remaining idle worktree in sidebar
  /// order. `priorityTier` carries the ordinal so `prioritizeItems` keeps MRU
  /// order with an empty query; a typed query then hits the worktree-name title
  /// or the repo-name subtitle. The current worktree is rendered but flagged
  /// `isCurrentWorktree` so the overlay skips it for the default selection.
  static func worktreeSwitcherItems(
    from repositories: RepositoriesFeature.State
  ) -> [CommandPaletteItem] {
    let mruRank: [Worktree.ID: Int] = Dictionary(
      repositories.worktreeMRU.enumerated().map { ($1, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let currentWorktreeID = repositories.selectedWorktreeID
    let idleRows = repositories.orderedSidebarItems().filter { $0.lifecycle == .idle }
    let ordered =
      idleRows.enumerated().sorted { lhs, rhs in
        switch (mruRank[lhs.element.id], mruRank[rhs.element.id]) {
        case let (lhsRank?, rhsRank?): return lhsRank < rhsRank
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return lhs.offset < rhs.offset
        }
      }
      .map(\.element)

    return ordered.enumerated().map { index, row in
      let section = repositories.sidebar.sections[row.repositoryID]
      let resolvedRepositoryName = repositories.repositoryName(for: row.repositoryID)
      if resolvedRepositoryName == nil {
        commandPaletteLogger.warning(
          "Worktree switcher row \(row.id) resolved no repository name for \(row.repositoryID)."
        )
      }
      // Mirror the sidebar: the repo's custom color / title live on the sidebar
      // section (`repositoryAccent` is unused), a per-worktree override on the
      // row. Git rows tint the worktree name over the repo name; folders collapse
      // to their own name with no subtitle; the host stays a distinct badge.
      let repoColor = section?.color
      let repositoryName = Repository.sidebarDisplayName(
        custom: section?.title,
        fallback: resolvedRepositoryName ?? "Repository"
      )
      let hostInfo = row.host?.displayAuthority
      // Mirror the sidebar's leading glyph. Missing wins over folder wins over
      // the pull-request icon, matching `IconContent`; rows are idle-only here.
      // A pull request whose head branch no longer matches the worktree is
      // treated as none, mirroring `WorktreePullRequestDisplay`'s stale guard.
      let matchedPullRequest = row.pullRequest.flatMap { pullRequest in
        pullRequest.headRefName == nil || pullRequest.headRefName == row.branchName ? pullRequest : nil
      }
      let icon: CommandPaletteItem.WorktreeRowIcon =
        row.isMissing
        ? .missing
        : row.isFolder
          ? .folder
          : .pullRequest(
            SidebarPullRequestIcon.resolve(matchedPullRequest),
            checkBadge: SidebarCheckBadgeState.resolve(matchedPullRequest)
          )
      let title: String
      let subtitle: String?
      let style: CommandPaletteItem.WorktreeRowStyle
      if row.isFolder {
        // Fall back to the row's own name (never a generic constant) so a
        // not-yet-loaded remote folder stays identifiable as its whole title.
        title = Repository.sidebarDisplayName(
          custom: section?.title ?? row.customTitle,
          fallback: resolvedRepositoryName ?? row.name
        )
        subtitle = nil
        style = .init(titleTint: repoColor ?? row.customTint, repoTint: nil, hostInfo: hostInfo, icon: icon)
      } else {
        title = SidebarDisplayName.resolved(custom: row.customTitle, fallback: row.name) ?? row.name
        subtitle = repositoryName
        style = .init(titleTint: row.customTint, repoTint: repoColor, hostInfo: hostInfo, icon: icon)
      }
      return CommandPaletteItem(
        id: CommandPaletteItemID.worktreeSelect(row.id),
        title: title,
        subtitle: subtitle,
        kind: .worktreeSelect(row.id),
        priorityTier: index,
        isCurrentWorktree: row.id == currentWorktreeID,
        worktreeStyle: style
      )
    }
  }
}

private func pullRequestItems(
  pullRequest: GithubPullRequest,
  worktreeID: Worktree.ID,
  repositoryID: Repository.ID
) -> [CommandPaletteItem] {
  let state = pullRequest.state.uppercased()
  let isOpen = state == "OPEN"
  let isDraft = pullRequest.isDraft
  let mergeReadiness = PullRequestMergeReadiness(pullRequest: pullRequest)
  let checks = pullRequest.statusCheckRollup?.checks ?? []
  let breakdown = PullRequestCheckBreakdown(checks: checks)
  let hasFailingChecks = breakdown.failed > 0
  let canMerge = isOpen && !isDraft && !mergeReadiness.isBlocking

  func makeReadyItem() -> CommandPaletteItem? {
    guard isOpen && isDraft else { return nil }
    return CommandPaletteItem(
      id: CommandPaletteItemID.pullRequestReady(repositoryID),
      title: "Mark PR Ready for Review",
      subtitle: pullRequest.title,
      kind: .markPullRequestReady(worktreeID),
      priorityTier: 0
    )
  }

  func makeFailingItems() -> [CommandPaletteItem] {
    guard isOpen && hasFailingChecks else { return [] }
    let hasFailingCheckWithDetails = checks.contains { $0.checkState == .failure && $0.detailsUrl != nil }
    let leadingTier = isDraft ? 1 : 0
    let followupTier = leadingTier + 1
    var failingItems: [CommandPaletteItem] = []
    if hasFailingCheckWithDetails {
      failingItems.append(
        CommandPaletteItem(
          id: CommandPaletteItemID.pullRequestCopyFailingJobURL(repositoryID),
          title: "Copy failing job URL",
          subtitle: pullRequest.title,
          kind: .copyFailingJobURL(worktreeID),
          priorityTier: leadingTier
        )
      )
    }
    failingItems.append(
      CommandPaletteItem(
        id: CommandPaletteItemID.pullRequestCopyCiLogs(repositoryID),
        title: "Copy CI Failure Logs",
        subtitle: pullRequest.title,
        kind: .copyCiFailureLogs(worktreeID),
        priorityTier: hasFailingCheckWithDetails ? followupTier : leadingTier
      )
    )
    failingItems.append(
      CommandPaletteItem(
        id: CommandPaletteItemID.pullRequestRerunFailedJobs(repositoryID),
        title: "Re-run Failed Jobs",
        subtitle: pullRequest.title,
        kind: .rerunFailedJobs(worktreeID),
        priorityTier: followupTier
      )
    )
    if hasFailingCheckWithDetails {
      failingItems.append(
        CommandPaletteItem(
          id: CommandPaletteItemID.pullRequestOpenFailingCheck(repositoryID),
          title: "Open Failing Check Details",
          subtitle: pullRequest.title,
          kind: .openFailingCheckDetails(worktreeID),
          priorityTier: followupTier
        )
      )
    }
    return failingItems
  }

  var items: [CommandPaletteItem] = [
    CommandPaletteItem(
      id: CommandPaletteItemID.pullRequestOpen(repositoryID),
      title: "Open PR on GitHub",
      subtitle: pullRequest.title,
      kind: .openPullRequest(worktreeID),
      priorityTier: 2
    )
  ]

  if let readyItem = makeReadyItem() {
    items.append(readyItem)
  }

  items.append(contentsOf: makeFailingItems())

  if let mergeItem = makeMergePullRequestItem(
    canMerge: canMerge,
    breakdown: breakdown,
    repositoryID: repositoryID,
    worktreeID: worktreeID
  ) {
    items.append(mergeItem)
  }

  if let closeItem = makeClosePullRequestItem(
    isOpen: isOpen,
    repositoryID: repositoryID,
    worktreeID: worktreeID,
    pullRequestTitle: pullRequest.title
  ) {
    items.append(closeItem)
  }

  return items
}

private func makeMergePullRequestItem(
  canMerge: Bool,
  breakdown: PullRequestCheckBreakdown,
  repositoryID: Repository.ID,
  worktreeID: Worktree.ID
) -> CommandPaletteItem? {
  guard canMerge else { return nil }
  let successfulChecks = breakdown.passed
  let successfulChecksLabel =
    successfulChecks == 1
    ? "1 successful check"
    : "\(successfulChecks) successful checks"
  return CommandPaletteItem(
    id: CommandPaletteItemID.pullRequestMerge(repositoryID),
    title: "Merge PR",
    subtitle: "Merge Ready - \(successfulChecksLabel)",
    kind: .mergePullRequest(worktreeID),
    priorityTier: 0
  )
}

private func makeClosePullRequestItem(
  isOpen: Bool,
  repositoryID: Repository.ID,
  worktreeID: Worktree.ID,
  pullRequestTitle: String
) -> CommandPaletteItem? {
  guard isOpen else { return nil }
  return CommandPaletteItem(
    id: CommandPaletteItemID.pullRequestClose(repositoryID),
    title: "Close PR",
    subtitle: pullRequestTitle,
    kind: .closePullRequest(worktreeID),
    priorityTier: 1
  )
}

#if DEBUG
  private func debugToastItems() -> [CommandPaletteItem] {
    [
      CommandPaletteItem(
        id: "debug.toast.inProgress",
        title: "[Debug] Toast: In Progress",
        subtitle: "Simulates an in-progress toast",
        kind: .debugTestToast(.inProgress("Merging pull request…"))
      ),
      CommandPaletteItem(
        id: "debug.toast.success",
        title: "[Debug] Toast: Success",
        subtitle: "Simulates a success toast",
        kind: .debugTestToast(.success("Pull request merged"))
      ),
    ]
  }
#endif

private enum CommandPaletteItemID {
  static let ghosttyPrefix = "ghostty."
  static let globalCheckForUpdates = "global.check-for-updates"
  static let globalOpenSettings = "global.open-settings"
  static let globalOpenRepository = "global.open-repository"
  static let globalAddRemoteRepository = "global.add-remote-repository"
  static let globalNewWorktree = "global.new-worktree"
  static let globalRefreshWorktrees = "global.refresh-worktrees"
  static let globalViewArchivedWorktrees = "global.view-archived-worktrees"

  static var globalIDs: [CommandPaletteItem.ID] {
    [
      globalCheckForUpdates,
      globalOpenSettings,
      globalOpenRepository,
      globalAddRemoteRepository,
      globalNewWorktree,
      globalRefreshWorktrees,
      globalViewArchivedWorktrees,
    ]
  }

  static func worktreeSelect(_ worktreeID: Worktree.ID) -> CommandPaletteItem.ID {
    "worktree.\(worktreeID).select"
  }

  static func renameBranch(_ worktreeID: Worktree.ID) -> CommandPaletteItem.ID {
    "worktree.\(worktreeID).rename-branch"
  }

  static func ghosttyCommand(_ command: GhosttyCommand) -> CommandPaletteItem.ID {
    "\(ghosttyPrefix)\(command.action)|\(command.title)"
  }

  static func pullRequestIDs(repositoryID: Repository.ID) -> [CommandPaletteItem.ID] {
    [
      pullRequestOpen(repositoryID),
      pullRequestReady(repositoryID),
      pullRequestCopyFailingJobURL(repositoryID),
      pullRequestCopyCiLogs(repositoryID),
      pullRequestRerunFailedJobs(repositoryID),
      pullRequestOpenFailingCheck(repositoryID),
      pullRequestMerge(repositoryID),
      pullRequestClose(repositoryID),
    ]
  }

  static func pullRequestOpen(_ repositoryID: Repository.ID) -> CommandPaletteItem.ID {
    "pr.\(repositoryID).open"
  }

  static func pullRequestReady(_ repositoryID: Repository.ID) -> CommandPaletteItem.ID {
    "pr.\(repositoryID).ready"
  }

  static func pullRequestCopyFailingJobURL(_ repositoryID: Repository.ID) -> CommandPaletteItem.ID {
    "pr.\(repositoryID).copy-failing-job-url"
  }

  static func pullRequestCopyCiLogs(_ repositoryID: Repository.ID) -> CommandPaletteItem.ID {
    "pr.\(repositoryID).copy-ci-logs"
  }

  static func pullRequestRerunFailedJobs(_ repositoryID: Repository.ID) -> CommandPaletteItem.ID {
    "pr.\(repositoryID).rerun-failed-jobs"
  }

  static func pullRequestOpenFailingCheck(_ repositoryID: Repository.ID) -> CommandPaletteItem.ID {
    "pr.\(repositoryID).open-failing-check"
  }

  static func pullRequestMerge(_ repositoryID: Repository.ID) -> CommandPaletteItem.ID {
    "pr.\(repositoryID).merge"
  }

  static func pullRequestClose(_ repositoryID: Repository.ID) -> CommandPaletteItem.ID {
    "pr.\(repositoryID).close"
  }

  static func runScript(_ scriptID: UUID) -> CommandPaletteItem.ID {
    "script.\(scriptID).run"
  }

  static func stopScript(_ scriptID: UUID) -> CommandPaletteItem.ID {
    "script.\(scriptID).stop"
  }
}

private func prioritizeItems(
  items: [CommandPaletteItem],
  recencyByID: [CommandPaletteItem.ID: TimeInterval],
  now: Date
) -> [CommandPaletteItem] {
  let scored = items.enumerated().map { index, item in
    (item: item, index: index, recency: commandPaletteRecencyScore(item, recencyByID: recencyByID, now: now))
  }
  let sorted = scored.sorted { left, right in
    if left.item.priorityTier != right.item.priorityTier {
      return left.item.priorityTier < right.item.priorityTier
    }
    if left.item.priorityTier < CommandPaletteItem.defaultPriorityTier, left.recency != right.recency {
      return left.recency > right.recency
    }
    return left.index < right.index
  }
  return sorted.map(\.item)
}

private func commandPaletteRecencyScore(
  _ item: CommandPaletteItem,
  recencyByID: [CommandPaletteItem.ID: TimeInterval],
  now: Date
) -> Double {
  guard let lastActivated = recencyByID[item.id] else { return 0 }
  let ageSeconds = max(0, now.timeIntervalSince1970 - lastActivated)
  let ageDays = ageSeconds / 86_400
  let cappedAgeDays = min(ageDays, 30)
  return pow(0.5, cappedAgeDays / 7)
}

private func delegateAction(for kind: CommandPaletteItem.Kind) -> CommandPaletteFeature.Delegate {
  switch kind {
  case .worktreeSelect(let id):
    return .selectWorktree(id)
  case .checkForUpdates:
    return .checkForUpdates
  case .openSettings:
    return .openSettings
  case .newWorktree:
    return .newWorktree
  case .openRepository:
    return .openRepository
  case .addRemoteRepository:
    return .addRemoteRepository
  case .removeWorktree(let worktreeID, let repositoryID):
    return .removeWorktree(worktreeID, repositoryID)
  case .archiveWorktree(let worktreeID, let repositoryID):
    return .archiveWorktree(worktreeID, repositoryID)
  case .renameBranch(let worktreeID, let repositoryID):
    return .renameBranch(worktreeID, repositoryID)
  case .viewArchivedWorktrees:
    return .viewArchivedWorktrees
  case .refreshWorktrees:
    return .refreshWorktrees
  case .ghosttyCommand(let action):
    return .ghosttyCommand(action)
  case .openPullRequest,
    .markPullRequestReady,
    .mergePullRequest,
    .closePullRequest,
    .copyFailingJobURL,
    .copyCiFailureLogs,
    .rerunFailedJobs,
    .openFailingCheckDetails:
    return pullRequestDelegateAction(for: kind)!
  case .runScript, .stopScript:
    return scriptDelegateAction(for: kind)!
  #if DEBUG
    case .debugTestToast(let toast):
      return .debugTestToast(toast)
  #endif
  }
}

private func scriptDelegateAction(
  for kind: CommandPaletteItem.Kind
) -> CommandPaletteFeature.Delegate? {
  switch kind {
  case .runScript(let definition):
    return .runScript(definition)
  case .stopScript(let scriptID, let name):
    return .stopScript(scriptID, name: name)
  default:
    return nil
  }
}

private func pullRequestDelegateAction(
  for kind: CommandPaletteItem.Kind
) -> CommandPaletteFeature.Delegate? {
  switch kind {
  case .openPullRequest(let worktreeID):
    return .openPullRequest(worktreeID)
  case .markPullRequestReady(let worktreeID):
    return .markPullRequestReady(worktreeID)
  case .mergePullRequest(let worktreeID):
    return .mergePullRequest(worktreeID)
  case .closePullRequest(let worktreeID):
    return .closePullRequest(worktreeID)
  case .copyFailingJobURL(let worktreeID):
    return .copyFailingJobURL(worktreeID)
  case .copyCiFailureLogs(let worktreeID):
    return .copyCiFailureLogs(worktreeID)
  case .rerunFailedJobs(let worktreeID):
    return .rerunFailedJobs(worktreeID)
  case .openFailingCheckDetails(let worktreeID):
    return .openFailingCheckDetails(worktreeID)
  case .worktreeSelect,
    .checkForUpdates,
    .openSettings,
    .newWorktree,
    .openRepository,
    .addRemoteRepository,
    .removeWorktree,
    .archiveWorktree,
    .renameBranch,
    .viewArchivedWorktrees,
    .refreshWorktrees,
    .ghosttyCommand,
    .runScript,
    .stopScript:
    return nil
  #if DEBUG
    case .debugTestToast:
      return nil
  #endif
  }
}

private func scriptItems(
  scripts: [ScriptDefinition],
  runningScriptIDs: Set<UUID>
) -> [CommandPaletteItem] {
  var items: [CommandPaletteItem] = []
  for script in scripts {
    let trimmed = script.command.trimmingCharacters(in: .whitespacesAndNewlines)
    if runningScriptIDs.contains(script.id) {
      items.append(
        CommandPaletteItem(
          id: CommandPaletteItemID.stopScript(script.id),
          title: "Stop: \(script.displayName)",
          subtitle: nil,
          kind: .stopScript(script.id, name: script.displayName),
          priorityTier: 0
        )
      )
    } else if trimmed.isEmpty {
      // Surface unconfigured scripts as discoverable entries; picking one
      // navigates to the settings pane (handled in `runNamedScript`).
      items.append(
        CommandPaletteItem(
          id: CommandPaletteItemID.runScript(script.id),
          title: "Configure: \(script.displayName)",
          subtitle: "No command, opens Settings.",
          kind: .runScript(script),
          priorityTier: CommandPaletteItem.defaultPriorityTier + 50
        )
      )
    } else {
      items.append(
        CommandPaletteItem(
          id: CommandPaletteItemID.runScript(script.id),
          title: "Run: \(script.displayName)",
          subtitle: nil,
          kind: .runScript(script)
        )
      )
    }
  }
  return items
}

private func ghosttyCommandItems(_ commands: [GhosttyCommand]) -> [CommandPaletteItem] {
  commands.map { command in
    let subtitle = command.description.trimmingCharacters(in: .whitespacesAndNewlines)
    return CommandPaletteItem(
      id: CommandPaletteItemID.ghosttyCommand(command),
      title: command.title,
      subtitle: subtitle.isEmpty ? nil : subtitle,
      kind: .ghosttyCommand(command.action),
      priorityTier: CommandPaletteItem.defaultPriorityTier + 100
    )
  }
}

extension CommandPaletteFeature.State {
  /// Resets to the closed-palette invariant: no query, no selection, back to
  /// `.commands`. Callers own the `isPresented` transition.
  mutating func resetForDismiss() {
    query = ""
    selectedIndex = nil
    mode = .commands
  }
}

private func loadRecency(into state: inout CommandPaletteFeature.State) {
  @Shared(.appStorage("commandPaletteItemRecency")) var recency: [String: Double] = [:]
  state.recencyByItemID = recency
}

private func saveRecency(_ recencyByItemID: [CommandPaletteItem.ID: TimeInterval]) {
  @Shared(.appStorage("commandPaletteItemRecency")) var recency: [String: Double] = [:]
  $recency.withLock {
    $0 = recencyByItemID
  }
}

private struct CommandPaletteFuzzyScorer {
  private struct PreparedQueryPiece {
    let normalized: String
    let normalizedLowercase: String
    let expectContiguousMatch: Bool
  }

  private struct PreparedQuery {
    let piece: PreparedQueryPiece
    let values: [PreparedQueryPiece]?
  }

  private struct Match {
    var start: Int
    var end: Int
  }

  private struct ItemScore {
    var score: Int
    var labelMatch: [Match]?
    var descriptionMatch: [Match]?
  }

  private struct ScoredItem {
    let item: CommandPaletteItem
    let score: ItemScore
    let recencyScore: Double
    let index: Int
  }

  // Ranking tiers, highest to lowest. The whole point is that match *quality*
  // dominates: a direct (prefix/substring) hit always outranks a scattered
  // fuzzy hit, and a direct hit on the subtitle (e.g. a repo name) outranks a
  // scattered hit on the title (fuzzy must never beat direct). Adjacent tiers
  // are spaced by at least `maxIntraTierScore + 1`, and every in-tier score is
  // clamped to `maxIntraTierScore`, so a single query piece can never bleed into
  // the tier above. Multi-word queries sum per-piece tiered scores, so this
  // strict ordering is a single-piece guarantee.
  private static let maxIntraTierScore = (1 << 14) - 1
  private static let labelPrefixScoreThreshold = 1 << 17
  private static let labelSubstringScoreThreshold = (1 << 16) + (1 << 15)
  private static let subtitleDirectScoreThreshold = (1 << 16) + (1 << 14)
  private static let labelScoreThreshold = 1 << 16

  private let query: PreparedQuery
  private let allowNonContiguousMatches: Bool
  private let recencyByID: [CommandPaletteItem.ID: TimeInterval]
  private let now: Date

  init(
    query: String,
    recencyByID: [CommandPaletteItem.ID: TimeInterval],
    now: Date,
    allowNonContiguousMatches: Bool = true
  ) {
    self.query = Self.prepareQuery(query)
    self.allowNonContiguousMatches = allowNonContiguousMatches
    self.recencyByID = recencyByID
    self.now = now
  }

  func rankedItems(from items: [CommandPaletteItem]) -> [CommandPaletteItem] {
    let scoredItems = items.enumerated().compactMap { index, item in
      let score = scoreItem(item)
      return score.score > 0
        ? ScoredItem(
          item: item,
          score: score,
          recencyScore: recencyScore(for: item),
          index: index
        )
        : nil
    }
    let sorted = scoredItems.sorted { compare($0, $1) < 0 }
    return sorted.map(\.item)
  }

  private func scoreItem(_ item: CommandPaletteItem) -> ItemScore {
    guard !query.piece.normalized.isEmpty else {
      return ItemScore(score: 0, labelMatch: nil, descriptionMatch: nil)
    }

    let label = item.title
    let description = item.subtitle

    if let values = query.values, !values.isEmpty {
      return scoreItemMultiple(label: label, description: description, query: values)
    }

    return scoreItemSingle(label: label, description: description, query: query.piece)
  }

  private func scoreItemMultiple(
    label: String,
    description: String?,
    query: [PreparedQueryPiece]
  ) -> ItemScore {
    var totalScore = 0
    var totalLabelMatches: [Match] = []
    var totalDescriptionMatches: [Match] = []

    for piece in query {
      let score = scoreItemSingle(label: label, description: description, query: piece)
      if score.score == 0 {
        return ItemScore(score: 0, labelMatch: nil, descriptionMatch: nil)
      }
      totalScore += score.score
      if let labelMatch = score.labelMatch {
        totalLabelMatches.append(contentsOf: labelMatch)
      }
      if let descriptionMatch = score.descriptionMatch {
        totalDescriptionMatches.append(contentsOf: descriptionMatch)
      }
    }

    return ItemScore(
      score: totalScore,
      labelMatch: normalizeMatches(totalLabelMatches),
      descriptionMatch: normalizeMatches(totalDescriptionMatches)
    )
  }

  private func scoreItemSingle(
    label: String,
    description: String?,
    query: PreparedQueryPiece
  ) -> ItemScore {
    let allowNonContiguous = allowNonContiguousMatches && !query.expectContiguousMatch

    let (labelScore, labelPositions) = scoreFuzzy(
      target: label,
      query: query,
      allowNonContiguousMatches: allowNonContiguous
    )
    if labelScore > 0 {
      // Title matched. A direct hit (prefix, then contiguous substring) is
      // ranked into a strictly higher tier than a scattered subsequence hit.
      if let labelPrefixMatch = matchesPrefix(query: query.normalizedLowercase, target: label) {
        return tieredScore(
          tier: Self.labelPrefixScoreThreshold,
          intra: lengthBoost(query: query, target: label) + labelScore,
          labelMatch: labelPrefixMatch,
          descriptionMatch: nil
        )
      }
      if let labelSubstringMatch = matchesSubstring(query: query.normalizedLowercase, target: label) {
        // No length boost inside non-prefix tiers: equal-quality matches stay
        // tied on score so recency (MRU) decides them, see `compare`.
        return tieredScore(
          tier: Self.labelSubstringScoreThreshold,
          intra: labelScore,
          labelMatch: labelSubstringMatch,
          descriptionMatch: nil
        )
      }
      // The title matched only as a scattered subsequence. A direct subtitle hit
      // (the repo name) still outranks that, so check it before settling for the
      // scattered-title tier; otherwise a query that both scatter-matches the
      // worktree name and directly matches the repo name is buried in the
      // scattered band instead of ranking as the clean repo match it is.
      if let description, let subtitleDirectMatch = directMatch(target: description, query: query) {
        let (subtitleScore, _) = scoreFuzzy(
          target: description,
          query: query,
          allowNonContiguousMatches: allowNonContiguous
        )
        return tieredScore(
          tier: Self.subtitleDirectScoreThreshold,
          intra: subtitleScore,
          labelMatch: createMatches(labelPositions),
          descriptionMatch: subtitleDirectMatch
        )
      }
      return tieredScore(
        tier: Self.labelScoreThreshold,
        intra: labelScore,
        labelMatch: createMatches(labelPositions),
        descriptionMatch: nil
      )
    }

    if let description {
      let (descriptionScore, descriptionPositions) = scoreFuzzy(
        target: description,
        query: query,
        allowNonContiguousMatches: allowNonContiguous
      )
      if descriptionScore > 0 {
        // A direct hit on the subtitle (the repo name) outranks a scattered hit
        // on the title: a clean repo match must not lose to a fuzzy worktree
        // match. A scattered subtitle hit stays in the lowest band.
        if let subtitleDirectMatch = directMatch(target: description, query: query) {
          return tieredScore(
            tier: Self.subtitleDirectScoreThreshold,
            intra: descriptionScore,
            labelMatch: nil,
            descriptionMatch: subtitleDirectMatch
          )
        }
        return tieredScore(
          tier: 0,
          intra: descriptionScore,
          labelMatch: nil,
          descriptionMatch: createMatches(descriptionPositions)
        )
      }
    }

    return ItemScore(score: 0, labelMatch: nil, descriptionMatch: nil)
  }

  /// Compose a tier threshold with an in-tier refinement score, clamping the
  /// refinement so it can never bleed into the tier above (preserving the
  /// strict direct-beats-fuzzy ordering for pathologically long targets).
  private func tieredScore(
    tier: Int,
    intra: Int,
    labelMatch: [Match]?,
    descriptionMatch: [Match]?
  ) -> ItemScore {
    ItemScore(
      score: tier + min(intra, Self.maxIntraTierScore),
      labelMatch: labelMatch,
      descriptionMatch: descriptionMatch
    )
  }

  /// Favour shorter targets within a tier: the closer the query length is to the
  /// target length, the larger the boost (a 3/3 match beats a 3/8 match).
  private func lengthBoost(query: PreparedQueryPiece, target: String) -> Int {
    guard !target.isEmpty else { return 0 }
    return Int((Double(query.normalized.count) / Double(target.count) * 100).rounded())
  }

  private func compare(_ itemA: ScoredItem, _ itemB: ScoredItem) -> Int {
    let scoreA = itemA.score.score
    let scoreB = itemB.score.score

    if scoreA > Self.labelScoreThreshold || scoreB > Self.labelScoreThreshold {
      if scoreA != scoreB {
        return scoreA > scoreB ? -1 : 1
      }
      if scoreA < Self.labelPrefixScoreThreshold && scoreB < Self.labelPrefixScoreThreshold {
        let comparedByMatchLength = compareByMatchLength(itemA.score.labelMatch, itemB.score.labelMatch)
        if comparedByMatchLength != 0 {
          return comparedByMatchLength
        }
      }
      let labelA = itemA.item.title
      let labelB = itemB.item.title
      if labelA.count != labelB.count {
        return labelA.count - labelB.count
      }
    }

    if scoreA != scoreB {
      return scoreA > scoreB ? -1 : 1
    }

    let itemAHasLabelMatches = !(itemA.score.labelMatch?.isEmpty ?? true)
    let itemBHasLabelMatches = !(itemB.score.labelMatch?.isEmpty ?? true)
    if itemAHasLabelMatches && !itemBHasLabelMatches {
      return -1
    }
    if itemBHasLabelMatches && !itemAHasLabelMatches {
      return 1
    }

    if itemA.item.priorityTier != itemB.item.priorityTier {
      return itemA.item.priorityTier < itemB.item.priorityTier ? -1 : 1
    }

    // Recency (MRU) is a within-tier signal: once match quality (the score tier)
    // is equal, the more-recently-used row wins, and it wins BEFORE match-spread
    // so a navigation surface jumps to what you were just in.
    if itemA.recencyScore != itemB.recencyScore {
      return itemA.recencyScore > itemB.recencyScore ? -1 : 1
    }

    if let itemAMatchDistance = matchDistance(itemA),
      let itemBMatchDistance = matchDistance(itemB),
      itemAMatchDistance != itemBMatchDistance
    {
      return itemBMatchDistance > itemAMatchDistance ? -1 : 1
    }

    let fallback = fallbackCompare(itemA.item, itemB.item)
    if fallback != 0 {
      return fallback
    }

    return itemA.index - itemB.index
  }

  private func matchDistance(_ item: ScoredItem) -> Int? {
    var matchStart = -1
    var matchEnd = -1

    if let descriptionMatch = item.score.descriptionMatch, !descriptionMatch.isEmpty {
      matchStart = descriptionMatch[0].start
    } else if let labelMatch = item.score.labelMatch, !labelMatch.isEmpty {
      matchStart = labelMatch[0].start
    }

    if let labelMatch = item.score.labelMatch, !labelMatch.isEmpty {
      matchEnd = labelMatch[labelMatch.count - 1].end
      if let descriptionMatch = item.score.descriptionMatch,
        !descriptionMatch.isEmpty,
        let description = item.item.subtitle
      {
        matchEnd += description.count
      }
    } else if let descriptionMatch = item.score.descriptionMatch, !descriptionMatch.isEmpty {
      matchEnd = descriptionMatch[descriptionMatch.count - 1].end
    }

    guard matchStart != -1 else { return nil }
    return matchEnd - matchStart
  }

  private func compareByMatchLength(_ matchesA: [Match]?, _ matchesB: [Match]?) -> Int {
    guard let matchesA, let matchesB else { return 0 }
    if matchesA.isEmpty && matchesB.isEmpty {
      return 0
    }
    if matchesB.isEmpty {
      return -1
    }
    if matchesA.isEmpty {
      return 1
    }

    let matchLengthA = matchesA[matchesA.count - 1].end - matchesA[0].start
    let matchLengthB = matchesB[matchesB.count - 1].end - matchesB[0].start

    if matchLengthA == matchLengthB {
      return 0
    }
    return matchLengthB < matchLengthA ? 1 : -1
  }

  private func fallbackCompare(_ itemA: CommandPaletteItem, _ itemB: CommandPaletteItem) -> Int {
    let labelA = itemA.title
    let labelB = itemB.title
    let descriptionA = itemA.subtitle
    let descriptionB = itemB.subtitle

    let labelDescriptionALength = labelA.count + (descriptionA?.count ?? 0)
    let labelDescriptionBLength = labelB.count + (descriptionB?.count ?? 0)

    if labelDescriptionALength != labelDescriptionBLength {
      return labelDescriptionALength - labelDescriptionBLength
    }

    if labelA != labelB {
      return compareStrings(labelA, labelB)
    }

    if let descriptionA, let descriptionB, descriptionA != descriptionB {
      return compareStrings(descriptionA, descriptionB)
    }

    return 0
  }

  private func compareStrings(_ stringA: String, _ stringB: String) -> Int {
    switch stringA.localizedStandardCompare(stringB) {
    case .orderedAscending:
      return -1
    case .orderedDescending:
      return 1
    case .orderedSame:
      return 0
    }
  }

  private func recencyScore(for item: CommandPaletteItem) -> Double {
    commandPaletteRecencyScore(item, recencyByID: recencyByID, now: now)
  }

  private func scoreFuzzy(
    target: String,
    query: PreparedQueryPiece,
    allowNonContiguousMatches: Bool
  ) -> (Int, [Int]) {
    if target.isEmpty || query.normalized.isEmpty {
      return (0, [])
    }

    let targetChars = Array(target)
    let queryChars = Array(query.normalized)

    if targetChars.count < queryChars.count {
      return (0, [])
    }

    let targetLower = Array(target.lowercased())
    let queryLower = Array(query.normalizedLowercase)

    return doScoreFuzzy(
      query: queryChars,
      queryLower: queryLower,
      target: targetChars,
      targetLower: targetLower,
      allowNonContiguousMatches: allowNonContiguousMatches
    )
  }

  private func doScoreFuzzy(
    query: [Character],
    queryLower: [Character],
    target: [Character],
    targetLower: [Character],
    allowNonContiguousMatches: Bool
  ) -> (Int, [Int]) {
    let queryLength = query.count
    let targetLength = target.count
    let scores = Array(repeating: 0, count: queryLength * targetLength)
    var mutableScores = scores
    let matches = Array(repeating: 0, count: queryLength * targetLength)
    var mutableMatches = matches

    for queryIndex in 0..<queryLength {
      let queryIndexOffset = queryIndex * targetLength
      let queryIndexPreviousOffset = queryIndexOffset - targetLength
      let queryIndexGtNull = queryIndex > 0

      let queryCharAtIndex = query[queryIndex]
      let queryLowerCharAtIndex = queryLower[queryIndex]

      for targetIndex in 0..<targetLength {
        let targetIndexGtNull = targetIndex > 0

        let currentIndex = queryIndexOffset + targetIndex
        let leftIndex = currentIndex - 1
        let diagIndex = queryIndexPreviousOffset + targetIndex - 1

        let leftScore = targetIndexGtNull ? mutableScores[leftIndex] : 0
        let diagScore = queryIndexGtNull && targetIndexGtNull ? mutableScores[diagIndex] : 0

        let matchesSequenceLength =
          queryIndexGtNull && targetIndexGtNull ? mutableMatches[diagIndex] : 0

        let score: Int
        let scoreContext = CharScoreContext(
          queryChar: queryCharAtIndex,
          queryLowerChar: queryLowerCharAtIndex,
          target: target,
          targetLower: targetLower,
          targetIndex: targetIndex,
          matchesSequenceLength: matchesSequenceLength
        )
        if diagScore != 0 && queryIndexGtNull {
          score = computeCharScore(scoreContext)
        } else if queryIndexGtNull {
          score = 0
        } else {
          score = computeCharScore(scoreContext)
        }

        let isValidScore = score > 0 && diagScore + score >= leftScore

        if isValidScore
          && (allowNonContiguousMatches || queryIndexGtNull
            || startsWith(
              targetLower,
              queryLower,
              at: targetIndex
            ))
        {
          mutableMatches[currentIndex] = matchesSequenceLength + 1
          mutableScores[currentIndex] = diagScore + score
        } else {
          mutableMatches[currentIndex] = 0
          mutableScores[currentIndex] = leftScore
        }
      }
    }

    var positions: [Int] = []
    var queryIndex = queryLength - 1
    var targetIndex = targetLength - 1
    while queryIndex >= 0 && targetIndex >= 0 {
      let currentIndex = queryIndex * targetLength + targetIndex
      let match = mutableMatches[currentIndex]
      if match == 0 {
        targetIndex -= 1
      } else {
        positions.append(targetIndex)
        queryIndex -= 1
        targetIndex -= 1
      }
    }

    positions.reverse()
    let finalScore = mutableScores[queryLength * targetLength - 1]
    return (finalScore, positions)
  }

  private struct CharScoreContext {
    let queryChar: Character
    let queryLowerChar: Character
    let target: [Character]
    let targetLower: [Character]
    let targetIndex: Int
    let matchesSequenceLength: Int
  }

  private func computeCharScore(_ context: CharScoreContext) -> Int {
    if !considerAsEqual(context.queryLowerChar, context.targetLower[context.targetIndex]) {
      return 0
    }

    var score = 1

    if context.matchesSequenceLength > 0 {
      score += (min(context.matchesSequenceLength, 3) * 6)
      score += max(0, context.matchesSequenceLength - 3) * 3
    }

    if context.queryChar == context.target[context.targetIndex] {
      score += 1
    }

    if context.targetIndex == 0 {
      score += 8
    } else {
      let separatorBonus = scoreSeparatorAtPos(context.target[context.targetIndex - 1])
      if separatorBonus > 0 {
        score += separatorBonus
      } else if isUpper(context.target[context.targetIndex]) && context.matchesSequenceLength == 0 {
        score += 2
      }
    }

    return score
  }

  private func considerAsEqual(_ lhs: Character, _ rhs: Character) -> Bool {
    if lhs == rhs {
      return true
    }
    if lhs == "/" || lhs == "\\" {
      return rhs == "/" || rhs == "\\"
    }
    return false
  }

  private func scoreSeparatorAtPos(_ char: Character) -> Int {
    switch char {
    case "/", "\\":
      return 5
    case "_", "-", ".", " ", "'", "\"", ":":
      return 4
    default:
      return 0
    }
  }

  private func isUpper(_ char: Character) -> Bool {
    guard let scalar = String(char).unicodeScalars.first else { return false }
    return scalar.properties.isUppercase
  }

  private func startsWith(
    _ target: [Character],
    _ query: [Character],
    at index: Int
  ) -> Bool {
    guard index + query.count <= target.count else { return false }
    for queryIndex in 0..<query.count where target[index + queryIndex] != query[queryIndex] {
      return false
    }
    return true
  }

  private func createMatches(_ offsets: [Int]) -> [Match] {
    var matches: [Match] = []
    var lastMatch: Match?

    for position in offsets {
      if var lastMatch, lastMatch.end == position {
        lastMatch.end += 1
        matches[matches.count - 1] = lastMatch
      } else {
        let match = Match(start: position, end: position + 1)
        matches.append(match)
        lastMatch = match
      }
    }

    return matches
  }

  private func normalizeMatches(_ matches: [Match]) -> [Match]? {
    guard !matches.isEmpty else { return nil }

    let sortedMatches = matches.sorted { $0.start < $1.start }
    var normalizedMatches: [Match] = []
    var currentMatch: Match?

    for match in sortedMatches {
      if let existing = currentMatch, matchOverlaps(existing, match) {
        let merged = Match(
          start: min(existing.start, match.start),
          end: max(existing.end, match.end)
        )
        currentMatch = merged
        normalizedMatches[normalizedMatches.count - 1] = merged
      } else {
        currentMatch = match
        normalizedMatches.append(match)
      }
    }

    return normalizedMatches
  }

  private func matchOverlaps(_ matchA: Match, _ matchB: Match) -> Bool {
    if matchA.end < matchB.start {
      return false
    }
    if matchB.end < matchA.start {
      return false
    }
    return true
  }

  private func matchesPrefix(query: String, target: String) -> [Match]? {
    let targetLower = target.lowercased()
    guard targetLower.hasPrefix(query) else { return nil }
    return [Match(start: 0, end: query.count)]
  }

  /// A "direct" match on the target: a prefix hit, else a contiguous substring
  /// hit, else `nil`. Prefix positions win so highlighting anchors to the front.
  private func directMatch(target: String, query: PreparedQueryPiece) -> [Match]? {
    matchesPrefix(query: query.normalizedLowercase, target: target)
      ?? matchesSubstring(query: query.normalizedLowercase, target: target)
  }

  /// Contiguous (substring) match anywhere in the target. `query` is already
  /// normalized lowercase. Returns the first occurrence; treats `/` and `\` as
  /// equivalent, matching `considerAsEqual`. This is what separates a "direct"
  /// hit from a scattered subsequence hit.
  private func matchesSubstring(query: String, target: String) -> [Match]? {
    guard !query.isEmpty else { return nil }
    let queryChars = Array(query)
    let targetChars = Array(target.lowercased())
    guard queryChars.count <= targetChars.count else { return nil }
    for start in 0...(targetChars.count - queryChars.count) {
      var matched = true
      for offset in 0..<queryChars.count
      where !considerAsEqual(targetChars[start + offset], queryChars[offset]) {
        matched = false
        break
      }
      if matched {
        return [Match(start: start, end: start + queryChars.count)]
      }
    }
    return nil
  }

  private static func prepareQuery(_ original: String) -> PreparedQuery {
    let expectContiguousMatch = queryExpectsExactMatch(original)
    let normalized = normalizeQuery(original)
    let piece = PreparedQueryPiece(
      normalized: normalized.normalized,
      normalizedLowercase: normalized.normalizedLowercase,
      expectContiguousMatch: expectContiguousMatch
    )

    let splitPieces = original.split(separator: " ")
    var values: [PreparedQueryPiece] = []
    if splitPieces.count > 1 {
      for pieceValue in splitPieces {
        let value = String(pieceValue)
        let expectExactMatchPiece = queryExpectsExactMatch(value)
        let normalizedPiece = normalizeQuery(value)
        if normalizedPiece.normalized.isEmpty {
          continue
        }
        values.append(
          PreparedQueryPiece(
            normalized: normalizedPiece.normalized,
            normalizedLowercase: normalizedPiece.normalizedLowercase,
            expectContiguousMatch: expectExactMatchPiece
          )
        )
      }
    }

    return PreparedQuery(
      piece: piece,
      values: values.isEmpty ? nil : values
    )
  }

  private static func normalizeQuery(_ original: String) -> (normalized: String, normalizedLowercase: String) {
    var pathNormalized = String()
    pathNormalized.reserveCapacity(original.count)
    for char in original {
      if char == "\\" {
        pathNormalized.append("/")
      } else {
        pathNormalized.append(char)
      }
    }

    var normalized = String()
    normalized.reserveCapacity(pathNormalized.count)
    for char in pathNormalized {
      if char == "*" || char == "…" || char == "\"" || char.isWhitespace {
        continue
      }
      normalized.append(char)
    }

    if normalized.count > 1, normalized.hasSuffix("#") {
      normalized.removeLast()
    }

    return (normalized, normalized.lowercased())
  }

  private static func queryExpectsExactMatch(_ query: String) -> Bool {
    query.hasPrefix("\"") && query.hasSuffix("\"")
  }
}
