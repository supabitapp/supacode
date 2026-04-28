import AppKit
import ComposableArchitecture
import Sharing
import SupacodeSettingsFeature
import SupacodeSettingsShared
import SwiftUI

struct WorktreeDetailView: View {
  @Bindable var store: StoreOf<AppFeature>
  let terminalManager: WorktreeTerminalManager
  @Environment(CommandKeyObserver.self) private var commandKeyObserver

  var body: some View {
    detailBody(state: store.state)
  }

  private func detailBody(state: AppFeature.State) -> some View {
    let repositories = state.repositories
    let selectedRow = repositories.selectedRow(for: repositories.selectedWorktreeID)
    let selectedWorktree = repositories.worktree(for: repositories.selectedWorktreeID)
    let selectedWorktreeSummaries = selectedWorktreeSummaries(from: repositories)
    let showsMultiSelectionSummary = shouldShowMultiSelectionSummary(
      repositories: repositories,
      selectedWorktreeSummaries: selectedWorktreeSummaries
    )
    let loadingInfo = loadingInfo(
      for: selectedRow,
      selectedWorktreeID: repositories.selectedWorktreeID,
      repositories: repositories
    )
    let showsToolbarPlaceholder = shouldShowToolbarPlaceholder(
      repositories: repositories,
      loadingInfo: loadingInfo,
      selectedWorktree: selectedWorktree,
      selectedWorktreeSummaries: selectedWorktreeSummaries
    )
    let hasActiveWorktree =
      selectedWorktree != nil
      && loadingInfo == nil
      && !showsMultiSelectionSummary
    let openActionSelection = state.openActionSelection
    let scripts = state.scripts
    let runningScriptIDs = state.runningScriptIDs
    let notificationGroups = repositories.toolbarNotificationGroups(terminalManager: terminalManager)
    let unseenNotificationWorktreeCount = notificationGroups.reduce(0) { count, repository in
      count + repository.unseenWorktreeCount
    }
    let content = detailContent(
      repositories: repositories,
      loadingInfo: loadingInfo,
      selectedWorktree: selectedWorktree,
      selectedWorktreeSummaries: selectedWorktreeSummaries
    )
    .toolbar(removing: .title)
    .toolbar {
      if showsToolbarPlaceholder {
        ToolbarPlaceholderContent()
      } else if hasActiveWorktree, let selectedWorktree {
        let toolbarState = WorktreeToolbarState(
          title: selectedWorktree.name,
          rootURL: selectedWorktree.repositoryRootURL,
          kind: toolbarKind(for: selectedWorktree, repositories: repositories),
          statusToast: repositories.statusToast,
          notificationGroups: notificationGroups,
          unseenNotificationWorktreeCount: unseenNotificationWorktreeCount,
          openActionSelection: openActionSelection,
          showExtras: commandKeyObserver.isPressed,
          scripts: scripts,
          runningScriptIDs: runningScriptIDs,
        )
        WorktreeToolbarContent(
          toolbarState: toolbarState,
          onRenameBranch: { newBranch in
            store.send(.repositories(.requestRenameBranch(selectedWorktree.id, newBranch)))
          },
          onOpenWorktree: { action in
            store.send(.openWorktree(action))
          },
          onOpenActionSelectionChanged: { action in
            store.send(.openActionSelectionChanged(action))
          },
          onRevealInFinder: {
            store.send(.revealInFinder)
          },
          onSelectNotification: selectToolbarNotification,
          onDismissAllNotifications: { dismissAllToolbarNotifications(in: notificationGroups) },
          onRunScript: { store.send(.runScript) },
          onRunNamedScript: { store.send(.runNamedScript($0)) },
          onStopScript: { store.send(.stopScript($0)) },
          onStopRunScripts: { store.send(.stopRunScripts) },
          onManageScripts: {
            let repositoryID = selectedWorktree.repositoryRootURL.path(percentEncoded: false)
            store.send(.settings(.setSelection(.repositoryScripts(repositoryID))))
          }
        )
      }
    }
    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    let hasRunningRunScript = state.hasRunningRunScript
    let actions = makeFocusedActions(
      hasActiveWorktree: hasActiveWorktree,
      hasRunningRunScript: hasRunningRunScript
    )
    return applyFocusedActions(content: content, actions: actions)
  }

  private func selectedWorktreeSummaries(
    from repositories: RepositoriesFeature.State
  ) -> [MultiSelectedWorktreeSummary] {
    repositories.sidebarSelectedWorktreeIDs
      .compactMap { worktreeID in
        repositories.selectedRow(for: worktreeID).map {
          MultiSelectedWorktreeSummary(
            id: $0.id,
            repositoryID: $0.repositoryID,
            kind: $0.kind,
            name: $0.name,
            repositoryName: repositories.repositoryName(for: $0.repositoryID)
          )
        }
      }
      .sorted { lhs, rhs in
        let lhsRepository = lhs.repositoryName ?? ""
        let rhsRepository = rhs.repositoryName ?? ""
        if lhsRepository == rhsRepository {
          return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return lhsRepository.localizedCaseInsensitiveCompare(rhsRepository) == .orderedAscending
      }
  }

  private func shouldShowMultiSelectionSummary(
    repositories: RepositoriesFeature.State,
    selectedWorktreeSummaries: [MultiSelectedWorktreeSummary]
  ) -> Bool {
    !repositories.isShowingArchivedWorktrees
      && selectedWorktreeSummaries.count > 1
  }

  private func shouldShowToolbarPlaceholder(
    repositories: RepositoriesFeature.State,
    loadingInfo: WorktreeLoadingInfo?,
    selectedWorktree: Worktree?,
    selectedWorktreeSummaries: [MultiSelectedWorktreeSummary]
  ) -> Bool {
    if repositories.isShowingArchivedWorktrees {
      return false
    }
    if shouldShowMultiSelectionSummary(
      repositories: repositories,
      selectedWorktreeSummaries: selectedWorktreeSummaries
    ) {
      return false
    }
    if loadingInfo != nil {
      return true
    }
    if selectedWorktree != nil {
      return false
    }
    return !repositories.isInitialLoadComplete
  }

  @ViewBuilder
  private func detailContent(
    repositories: RepositoriesFeature.State,
    loadingInfo: WorktreeLoadingInfo?,
    selectedWorktree: Worktree?,
    selectedWorktreeSummaries: [MultiSelectedWorktreeSummary]
  ) -> some View {
    if repositories.isShowingArchivedWorktrees {
      ArchivedWorktreesDetailView(
        store: store.scope(state: \.repositories, action: \.repositories)
      )
    } else if shouldShowMultiSelectionSummary(
      repositories: repositories,
      selectedWorktreeSummaries: selectedWorktreeSummaries
    ) {
      MultiSelectedWorktreesDetailView(rows: selectedWorktreeSummaries)
    } else if let loadingInfo {
      WorktreeLoadingView(info: loadingInfo)
    } else if let selectedWorktree {
      let shouldRunSetupScript = repositories.pendingSetupScriptWorktreeIDs.contains(selectedWorktree.id)
      let shouldFocusTerminal = repositories.shouldFocusTerminal(for: selectedWorktree.id)
      WorktreeTerminalTabsView(
        worktree: selectedWorktree,
        manager: terminalManager,
        shouldRunSetupScript: shouldRunSetupScript,
        forceAutoFocus: shouldFocusTerminal,
        createTab: { store.send(.newTerminal) }
      )
      .id(selectedWorktree.id)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .ignoresSafeArea(.container, edges: .bottom)
      .onAppear {
        if shouldFocusTerminal {
          store.send(.repositories(.consumeTerminalFocus(selectedWorktree.id)))
        }
      }
    } else if !repositories.isInitialLoadComplete {
      DetailPlaceholderView()
    } else {
      EmptyStateView(store: store.scope(state: \.repositories, action: \.repositories))
    }
  }

  private func applyFocusedActions<Content: View>(
    content: Content,
    actions: FocusedActions
  ) -> some View {
    let resolvedSelection: OpenWorktreeAction? =
      actions.openSelectedWorktree != nil
      ? OpenWorktreeAction.availableSelection(store.openActionSelection) : nil
    return
      content
      .focusedSceneValue(\.openSelectedWorktreeAction, actions.openSelectedWorktree)
      .focusedSceneValue(\.revealInFinderAction, actions.revealInFinder)
      .focusedSceneValue(\.openActionSelection, resolvedSelection)
      .focusedSceneValue(\.newTerminalAction, actions.newTerminal)
      .focusedValue(\.closeTabAction, actions.closeTab)
      .focusedValue(\.closeSurfaceAction, actions.closeSurface)
      .focusedSceneValue(\.startSearchAction, actions.startSearch)
      .focusedSceneValue(\.searchSelectionAction, actions.searchSelection)
      .focusedSceneValue(\.navigateSearchNextAction, actions.navigateSearchNext)
      .focusedSceneValue(\.navigateSearchPreviousAction, actions.navigateSearchPrevious)
      .focusedSceneValue(\.endSearchAction, actions.endSearch)
      .focusedSceneValue(\.runScriptAction, actions.runScript)
      .focusedSceneValue(\.stopRunScriptAction, actions.stopRunScript)
  }

  private func makeFocusedActions(
    hasActiveWorktree: Bool,
    hasRunningRunScript: Bool
  ) -> FocusedActions {
    func action(_ appAction: AppFeature.Action) -> (() -> Void)? {
      hasActiveWorktree ? { store.send(appAction) } : nil
    }
    return FocusedActions(
      openSelectedWorktree: action(.openSelectedWorktree),
      revealInFinder: action(.revealInFinder),
      newTerminal: action(.newTerminal),
      closeTab: action(.closeTab),
      closeSurface: action(.closeSurface),
      startSearch: action(.startSearch),
      searchSelection: action(.searchSelection),
      navigateSearchNext: action(.navigateSearchNext),
      navigateSearchPrevious: action(.navigateSearchPrevious),
      endSearch: action(.endSearch),
      runScript: hasActiveWorktree ? { store.send(.runScript) } : nil,
      stopRunScript: hasRunningRunScript ? { store.send(.stopRunScripts) } : nil,
    )
  }

  private func selectToolbarNotification(
    _ worktreeID: Worktree.ID,
    _ notification: WorktreeTerminalNotification
  ) {
    store.send(.repositories(.selectWorktree(worktreeID)))
    if let terminalState = terminalManager.stateIfExists(for: worktreeID) {
      _ = terminalState.focusSurface(id: notification.surfaceId)
    }
  }

  private func dismissAllToolbarNotifications(in groups: [ToolbarNotificationRepositoryGroup]) {
    for repositoryGroup in groups {
      for worktreeGroup in repositoryGroup.worktrees {
        terminalManager.stateIfExists(for: worktreeGroup.id)?.dismissAllNotifications()
      }
    }
  }

  private struct FocusedActions {
    let openSelectedWorktree: (() -> Void)?
    let revealInFinder: (() -> Void)?
    let newTerminal: (() -> Void)?
    let closeTab: (() -> Void)?
    let closeSurface: (() -> Void)?
    let startSearch: (() -> Void)?
    let searchSelection: (() -> Void)?
    let navigateSearchNext: (() -> Void)?
    let navigateSearchPrevious: (() -> Void)?
    let endSearch: (() -> Void)?
    let runScript: (() -> Void)?
    let stopRunScript: (() -> Void)?
  }

  fileprivate struct WorktreeToolbarState {
    // Folders have no git remote, so the PR payload is scoped to
    // `.git` — this makes "folder with a pull request" unrepresentable.
    enum Kind {
      case git(pullRequest: GithubPullRequest?)
      case folder
    }

    let title: String
    let rootURL: URL
    let kind: Kind
    let statusToast: RepositoriesFeature.StatusToast?
    let notificationGroups: [ToolbarNotificationRepositoryGroup]
    let unseenNotificationWorktreeCount: Int
    let openActionSelection: OpenWorktreeAction
    let showExtras: Bool
    let scripts: [ScriptDefinition]
    let runningScriptIDs: Set<UUID>

    var isFolder: Bool {
      if case .folder = kind { true } else { false }
    }

    var pullRequest: GithubPullRequest? {
      if case .git(let pullRequest) = kind { pullRequest } else { nil }
    }

    /// The first `.run`-kind script, if any.
    var primaryScript: ScriptDefinition? {
      scripts.primaryScript
    }

    /// Whether any `.run`-kind script is currently running.
    var hasRunningRunScript: Bool {
      scripts.hasRunningRunScript(in: runningScriptIDs)
    }

    var runScriptHelpText: String {
      @Shared(.settingsFile) var settingsFile
      let display = AppShortcuts.runScript.effective(from: settingsFile.global.shortcutOverrides)?.display ?? "none"
      return "Run Script (\(display))"
    }

    var stopRunScriptHelpText: String {
      @Shared(.settingsFile) var settingsFile
      let display = AppShortcuts.stopRunScript.effective(from: settingsFile.global.shortcutOverrides)?.display ?? "none"
      return "Stop Script (\(display))"
    }
  }

  fileprivate struct WorktreeToolbarContent: ToolbarContent {
    let toolbarState: WorktreeToolbarState
    let onRenameBranch: (String) -> Void
    let onOpenWorktree: (OpenWorktreeAction) -> Void
    let onOpenActionSelectionChanged: (OpenWorktreeAction) -> Void
    let onRevealInFinder: () -> Void
    let onSelectNotification: (Worktree.ID, WorktreeTerminalNotification) -> Void
    let onDismissAllNotifications: () -> Void
    let onRunScript: () -> Void
    let onRunNamedScript: (ScriptDefinition) -> Void
    let onStopScript: (ScriptDefinition) -> Void
    let onStopRunScripts: () -> Void
    let onManageScripts: () -> Void

    var body: some ToolbarContent {
      ToolbarItem {
        WorktreeDetailTitleView(
          title: toolbarState.title,
          rootURL: toolbarState.rootURL,
          isFolder: toolbarState.isFolder,
          onRenameBranch: onRenameBranch
        )
      }

      ToolbarSpacer(.flexible)

      ToolbarItemGroup {
        ToolbarStatusView(
          toast: toolbarState.statusToast,
          pullRequest: toolbarState.pullRequest
        )
        .padding(.horizontal)
        if !toolbarState.notificationGroups.isEmpty {
          ToolbarNotificationsPopoverButton(
            groups: toolbarState.notificationGroups,
            unseenWorktreeCount: toolbarState.unseenNotificationWorktreeCount,
            onSelectNotification: onSelectNotification,
            onDismissAll: onDismissAllNotifications
          )
        }
      }

      ToolbarSpacer(.flexible)

      ToolbarItem {
        openMenu(
          openActionSelection: toolbarState.openActionSelection,
          showExtras: toolbarState.showExtras
        )
      }
      ToolbarSpacer(.fixed)

      ToolbarItem {
        ScriptMenu(
          toolbarState: toolbarState,
          onRunScript: onRunScript,
          onRunNamedScript: onRunNamedScript,
          onStopScript: onStopScript,
          onStopRunScripts: onStopRunScripts,
          onManageScripts: onManageScripts
        )
        // Rebuild the NSMenu per repo; the toolbar Menu otherwise caches first-opened items (#280).
        .id(toolbarState.rootURL)
        .transaction { $0.animation = nil }
      }
    }

    @ViewBuilder
    private func openMenu(openActionSelection: OpenWorktreeAction, showExtras: Bool) -> some View {
      let availableActions = OpenWorktreeAction.availableCases.filter { $0 != .finder }
      let resolved = OpenWorktreeAction.availableSelection(openActionSelection)
      let primarySelection = resolved == .finder ? availableActions.first : resolved
      if let primarySelection {
        Menu {
          ForEach(availableActions) { action in
            let isDefault = action == primarySelection
            Button {
              onOpenActionSelectionChanged(action)
              onOpenWorktree(action)
            } label: {
              OpenWorktreeActionMenuLabelView(action: action, shortcutHint: nil)
            }
            .buttonStyle(.plain)
            .help(openActionHelpText(for: action, isDefault: isDefault))
          }
          Divider()
          Button {
            onRevealInFinder()
          } label: {
            OpenWorktreeActionMenuLabelView(action: .finder, shortcutHint: nil)
          }
          .help("Reveal in Finder (\(resolveShortcutDisplay(for: AppShortcuts.revealInFinder)))")
        } label: {
          OpenWorktreeActionMenuLabelView(
            action: primarySelection,
            shortcutHint: showExtras ? resolveShortcutDisplay(for: AppShortcuts.openWorktree, fallback: "") : nil
          )
        } primaryAction: {
          onOpenWorktree(primarySelection)
        }
        .help(openActionHelpText(for: primarySelection, isDefault: true))
      }
    }

    private func openActionHelpText(for action: OpenWorktreeAction, isDefault: Bool) -> String {
      guard isDefault else { return action.title }
      return "\(action.title) (\(resolveShortcutDisplay(for: AppShortcuts.openWorktree)))"
    }
  }

  private func toolbarKind(
    for selectedWorktree: Worktree,
    repositories: RepositoriesFeature.State
  ) -> WorktreeToolbarState.Kind {
    let selectedRow = repositories.selectedRow(for: selectedWorktree.id)
    guard selectedRow?.isFolder != true else { return .folder }
    guard let pullRequest = repositories.worktreeInfo(for: selectedWorktree.id)?.pullRequest else {
      return .git(pullRequest: nil)
    }
    // Only surface the PR when its head branch matches the current
    // worktree — otherwise stale info sticks around after a rename
    // or branch switch.
    let matches = pullRequest.headRefName == nil || pullRequest.headRefName == selectedWorktree.name
    return .git(pullRequest: matches ? pullRequest : nil)
  }

  private func loadingInfo(
    for selectedRow: SidebarItemModel?,
    selectedWorktreeID: Worktree.ID?,
    repositories: RepositoriesFeature.State
  ) -> WorktreeLoadingInfo? {
    guard let selectedRow else { return nil }
    let repositoryName = repositories.repositoryName(for: selectedRow.repositoryID)
    switch selectedRow.status {
    case .deleting(inTerminal: false):
      return WorktreeLoadingInfo(
        name: selectedRow.name,
        repositoryName: repositoryName,
        kind: .removing(isFolder: selectedRow.isFolder)
      )
    case .archiving, .deleting(inTerminal: true):
      // The script runs in a terminal tab, so let the
      // terminal view show through instead of a loading overlay.
      return nil
    case .idle:
      return nil
    case .pending:
      break
    }
    if selectedRow.isPending {
      let pending = repositories.pendingWorktree(for: selectedWorktreeID)
      let progress = pending?.progress
      let displayName = progress?.worktreeName ?? selectedRow.name
      return WorktreeLoadingInfo(
        name: displayName,
        repositoryName: repositoryName,
        kind: .creating(
          WorktreeLoadingInfo.Progress(
            statusTitle: progress?.titleText ?? selectedRow.name,
            statusDetail: progress?.detailText ?? selectedRow.detail,
            statusCommand: progress?.commandText,
            statusLines: progress?.liveOutputLines ?? []
          )
        )
      )
    }
    return nil
  }
}

// MARK: - Detail placeholder.

private struct DetailPlaceholderView: View {
  @State private var messageIndex = Int.random(in: 0..<Self.messages.count)

  private static let messages = [
    "Preparing your worktree…",
    "Getting your agents ready…",
    "Syncing git state…",
    "Indexing branches…",
    "Staging your workspace…",
    "Orchestrating terminals…",
    "Spinning up runners…",
    "Warming up shells…",
    "Aligning refs…",
    "Assembling task graph…",
    "Tuning buffers…",
    "Hydrating caches…",
    "Resolving merge conflicts telepathically…",
    "Teaching agents to say less…",
    "Removing \"you're absolutely right!\"…",
    "Evicting polite overcommit…",
    "Reducing agent flattery…",
    "Sharpening code opinions…",
    "Making the bots decisive…",
    "Debouncing Claude Code pleasantries…",
    "Calibrating Codex confidence…",
    "Pruning Claude Code hedges…",
    "Clearing Codex verbosity…",
    "Convincing Copilot to stop guessing…",
    "Telling Cursor to read the error message…",
    "Revoking Gemini's thesaurus access…",
  ]

  var body: some View {
    VStack(spacing: 12) {
      ProgressView()
        .controlSize(.large)
      Text(Self.messages[messageIndex])
        .font(.title3)
        .foregroundStyle(.secondary)
        .contentTransition(.numericText())
        .shimmer(isActive: true)
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
    .task {
      let clock = ContinuousClock()
      while !Task.isCancelled {
        try? await clock.sleep(for: .seconds(1.8))
        withAnimation(.easeInOut(duration: 0.25)) {
          // Pick a random index that differs from the current one.
          var next = Int.random(in: 0..<Self.messages.count - 1)
          if next >= messageIndex { next += 1 }
          messageIndex = next
        }
      }
    }
  }
}

// MARK: - Toolbar placeholder.

private struct ToolbarPlaceholderContent: ToolbarContent {
  var body: some ToolbarContent {
    ToolbarItem {
      Button {
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "arrow.trianglehead.branch")
            .foregroundStyle(.secondary)
          Text("feature/branch")
        }
        .font(.headline)
      }
      .redacted(reason: .placeholder)
      .shimmer(isActive: true)
    }

    ToolbarSpacer(.flexible)

    ToolbarItemGroup {
      HStack(spacing: 8) {
        Image(systemName: "sun.max.fill")
          .font(.callout)
        Text("00:00 – Open Command Palette (⌘P)")
          .font(.footnote)
          .monospaced()
      }
      .foregroundStyle(.secondary)
      .padding(.horizontal)
      .redacted(reason: .placeholder)
      .shimmer(isActive: true)
    }

    ToolbarSpacer(.flexible)

    ToolbarItemGroup {
      Button {
      } label: {
        HStack(spacing: 4) {
          Image(systemName: "doc.text")
          Text("VS Code (⌘O)")
        }
      }
      .font(.caption)
      .redacted(reason: .placeholder)
      .shimmer(isActive: true)
    }
    ToolbarSpacer(.fixed)

    ToolbarItem {
      Button {
      } label: {
        Label {
          Text("Run")
        } icon: {
          Image(systemName: "play")
        }
        .labelStyle(.titleAndIcon)
      }
      .redacted(reason: .placeholder)
      .shimmer(isActive: true)
    }
  }
}

private struct MultiSelectedWorktreeSummary: Identifiable {
  let id: Worktree.ID
  let repositoryID: Repository.ID
  let kind: SidebarItemModel.Kind
  let name: String
  let repositoryName: String?
}

/// Resolves a shortcut's display string from the user's settings.
private func resolveShortcutDisplay(for shortcut: AppShortcut, fallback: String = "none") -> String {
  @Shared(.settingsFile) var settingsFile
  let display = shortcut.effective(from: settingsFile.global.shortcutOverrides)?.display ?? fallback
  return display.isEmpty ? fallback : display
}

private struct MultiSelectedWorktreesDetailView: View {
  let rows: [MultiSelectedWorktreeSummary]

  private let visibleRowsLimit = 8

  private var worktreeRows: [MultiSelectedWorktreeSummary] {
    rows.filter { $0.kind == .git }
  }

  private var folderRows: [MultiSelectedWorktreeSummary] {
    rows.filter { $0.kind == .folder }
  }

  private var isMixedKindSelection: Bool {
    !worktreeRows.isEmpty && !folderRows.isEmpty
  }

  var body: some View {
    let archiveShortcut = KeyboardShortcut(.delete, modifiers: .command).display
    let deleteShortcut = KeyboardShortcut(.delete, modifiers: [.command, .shift]).display
    VStack(alignment: .leading, spacing: 20) {
      Text("\(rows.count) items selected")
        .font(.title3)

      if !worktreeRows.isEmpty {
        selectionSection(
          title: "Worktrees (\(worktreeRows.count))",
          rows: worktreeRows,
          actions: isMixedKindSelection
            ? []
            : [
              "Archive selected (\(archiveShortcut))",
              "Delete selected (\(deleteShortcut))",
              "Right-click any selected worktree to apply actions to all selected worktrees.",
            ]
        )
      }

      if !folderRows.isEmpty {
        selectionSection(
          title: "Folders (\(folderRows.count))",
          rows: folderRows,
          actions: isMixedKindSelection
            ? []
            : [
              "Remove selected from Supacode (\(deleteShortcut))",
              "Right-click any selected folder to remove them all from Supacode.",
            ]
        )
      }

      if isMixedKindSelection {
        VStack(alignment: .leading, spacing: 6) {
          Label("No bulk action available", systemImage: "exclamationmark.triangle")
            .font(.headline)
          Text(
            "Worktrees and folders don't share bulk actions. Deselect "
              + "one kind to archive/delete worktrees or remove folders."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }

      Spacer(minLength: 0)
    }
    .padding(20)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  @ViewBuilder
  private func selectionSection(
    title: String,
    rows: [MultiSelectedWorktreeSummary],
    actions: [String]
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.headline)
      ForEach(Array(rows.prefix(visibleRowsLimit))) { row in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(row.name)
            .lineLimit(1)
          if let repositoryName = row.repositoryName, row.kind == .git {
            Text(repositoryName)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        .font(.body)
      }
      if rows.count > visibleRowsLimit {
        Text("+\(rows.count - visibleRowsLimit) more")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if !actions.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          Text("Available actions")
            .font(.subheadline)
            .foregroundStyle(.secondary)
          ForEach(actions, id: \.self) { action in
            Text(action)
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 4)
      }
    }
  }
}

/// Menu with primary action for running scripts in the toolbar.
/// Click runs the default script, stops running scripts, or opens settings;
/// long-press/arrow opens the full script list.
private struct ScriptMenu: View {
  let toolbarState: WorktreeDetailView.WorktreeToolbarState
  let onRunScript: () -> Void
  let onRunNamedScript: (ScriptDefinition) -> Void
  let onStopScript: (ScriptDefinition) -> Void
  let onStopRunScripts: () -> Void
  let onManageScripts: () -> Void
  @Environment(CommandKeyObserver.self) private var commandKeyObserver

  private var primaryScript: ScriptDefinition? {
    toolbarState.primaryScript
  }

  var body: some View {
    let hasRunning = toolbarState.hasRunningRunScript
    Menu {
      ForEach(toolbarState.scripts) { script in
        let isRunning = toolbarState.runningScriptIDs.contains(script.id)
        Button {
          if isRunning {
            onStopScript(script)
          } else {
            onRunNamedScript(script)
          }
        } label: {
          Label {
            Text(isRunning ? "Stop \(script.displayName)" : script.displayName)
          } icon: {
            Image.tintedSymbol(
              isRunning ? "stop" : script.resolvedSystemImage,
              color: script.resolvedTintColor.nsColor,
            )
          }
        }
        .help(isRunning ? "Stop \(script.displayName)." : "Run \(script.displayName).")
      }
      if !toolbarState.scripts.isEmpty {
        Divider()
      }
      Button("Manage Scripts…") {
        onManageScripts()
      }
      .help("Open repository settings to manage scripts.")
    } label: {
      scriptLabel(hasRunning: hasRunning)
    } primaryAction: {
      if hasRunning {
        onStopRunScripts()
      } else if primaryScript != nil {
        onRunScript()
      } else {
        onManageScripts()
      }
    }
    .help(primaryHelpText(hasRunning: hasRunning))
  }

  @ViewBuilder
  private func scriptLabel(hasRunning: Bool) -> some View {
    let icon = hasRunning ? "stop" : (primaryScript?.resolvedSystemImage ?? "play")
    let label = hasRunning ? "Stop" : (primaryScript?.displayName ?? "Run")
    let shortcut = hasRunning ? AppShortcuts.stopRunScript : AppShortcuts.runScript
    Label {
      Text(
        commandKeyObserver.isPressed
          ? resolveShortcutDisplay(for: shortcut, fallback: label)
          : label
      )
    } icon: {
      Image(systemName: icon)
        .accessibilityHidden(true)
    }.labelStyle(.titleAndIcon)
  }

  private func primaryHelpText(hasRunning: Bool) -> String {
    if hasRunning {
      return toolbarState.stopRunScriptHelpText
    }
    guard primaryScript != nil else {
      return "Configure scripts in Settings."
    }
    return toolbarState.runScriptHelpText
  }
}

@MainActor
private struct WorktreeToolbarPreview: View {
  private let toolbarState: WorktreeDetailView.WorktreeToolbarState
  private let commandKeyObserver: CommandKeyObserver

  init() {
    toolbarState = WorktreeDetailView.WorktreeToolbarState(
      title: "feature/toolbar-preview",
      rootURL: URL(fileURLWithPath: "/tmp/preview"),
      kind: .git(pullRequest: nil),
      statusToast: nil,
      notificationGroups: [],
      unseenNotificationWorktreeCount: 0,
      openActionSelection: .finder,
      showExtras: false,
      scripts: [ScriptDefinition(kind: .run, command: "npm run dev")],
      runningScriptIDs: [],
    )
    let observer = CommandKeyObserver()
    observer.isPressed = false
    commandKeyObserver = observer
  }

  var body: some View {
    NavigationStack {
      Text("Worktree Toolbar")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .toolbar {
      WorktreeDetailView.WorktreeToolbarContent(
        toolbarState: toolbarState,
        onRenameBranch: { _ in },
        onOpenWorktree: { _ in },
        onOpenActionSelectionChanged: { _ in },
        onRevealInFinder: {},
        onSelectNotification: { _, _ in },
        onDismissAllNotifications: {},
        onRunScript: {},
        onRunNamedScript: { _ in },
        onStopScript: { _ in },
        onStopRunScripts: {},
        onManageScripts: {}
      )
    }
    .environment(commandKeyObserver)
    .frame(width: 900, height: 160)
  }
}

#Preview("Worktree Toolbar") {
  WorktreeToolbarPreview()
}
