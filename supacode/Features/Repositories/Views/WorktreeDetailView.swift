import AppKit
import ComposableArchitecture
import OrderedCollections
import Sharing
import SupacodeSettingsFeature
import SupacodeSettingsShared
import SwiftUI

#if DEBUG
  private nonisolated let detailRenderLogger = SupaLogger("DetailRender")
#endif

struct WorktreeDetailView: View {
  @Bindable var store: StoreOf<AppFeature>
  let terminalManager: WorktreeTerminalManager
  @Shared(.appStorage("worktreeRowHideSubtitleOnMatch")) private var hideSubtitleOnMatch = true
  @Shared(.settingsFile) private var settingsFile: SettingsFile

  private var agentBadgesEnabled: Bool { settingsFile.global.agentPresenceBadgesEnabled }

  var body: some View {
    #if DEBUG
      let _ = Self._printChanges()
      detailRenderLogger.info("WorktreeDetailView.body re-rendered")
    #endif
    return detailBody(state: store.state)
  }

  private func detailBody(state: AppFeature.State) -> some View {
    let repositories = state.repositories
    // Reads the cached slice instead of `sidebarItems[id:]` so per-leaf agent
    // / notification churn on the focused row doesn't invalidate this body.
    let selectedRow = repositories.selectedWorktreeSlice
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
      && selectedWorktree?.isMissing != true
    let openActionSelection = state.openActionSelection
    let repoScripts = state.repoScripts
    let globalScripts = state.globalScripts
    // Source `runningScriptIDs` from the slice instead of `state.runningScriptIDs`
    // so an unrelated `sidebarItems[id:].agents` mutation on the focused row
    // doesn't re-publish this. Same field, observed through the projected slice.
    let runningScriptIDs = Set(selectedRow?.runningScripts.ids ?? [])
    // `toolbarNotificationGroupsCache` is observed inside `ToolbarNotificationsPopoverButtonHost`
    // instead; reading it here would re-render the body on every notification.
    let content = detailContent(
      repositories: repositories,
      loadingInfo: loadingInfo,
      selectedWorktree: selectedWorktree,
      selectedSlice: selectedRow,
      selectedWorktreeSummaries: selectedWorktreeSummaries
    )
    .toolbar(removing: .title)
    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    .toolbar {
      if showsToolbarPlaceholder {
        ToolbarPlaceholderContent()
      } else if hasActiveWorktree, let selectedWorktree {
        let titleContent = Self.makeToolbarTitleContent(
          selectedWorktree: selectedWorktree,
          selectedRow: selectedRow,
          repositories: repositories,
          hideSubtitleOnMatch: hideSubtitleOnMatch
        )
        let toolbarState = WorktreeToolbarState(
          titleContent: titleContent,
          rootURL: selectedWorktree.repositoryRootURL,
          kind: toolbarKind(for: selectedWorktree, selectedRow: selectedRow),
          statusToast: repositories.statusToast,
          openActionSelection: openActionSelection,
          repoScripts: repoScripts,
          globalScripts: globalScripts,
          runningScriptIDs: runningScriptIDs,
        )
        WorktreeToolbarContent(
          toolbarState: toolbarState,
          terminalManager: terminalManager,
          repositoriesStore: store.scope(state: \.repositories, action: \.repositories),
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
          onRunScript: { store.send(.runScript) },
          onRunNamedScript: { store.send(.runNamedScript($0)) },
          onStopScript: { store.send(.stopScript($0)) },
          onStopRunScripts: { store.send(.stopRunScripts) },
          onManageRepoScripts: {
            let repositoryID = selectedWorktree.repositoryRootURL.path(percentEncoded: false)
            store.send(.settings(.setSelection(.repositoryScripts(repositoryID))))
          },
          onManageGlobalScripts: {
            store.send(.settings(.setSelection(.scripts)))
          }
        )
      }
    }
    let hasRunningRunScript = state.hasRunningRunScript
    let resolvedSelection: OpenWorktreeAction? =
      hasActiveWorktree ? OpenWorktreeAction.availableSelection(store.openActionSelection) : nil
    return applyFocusedActions(
      content: content,
      hasActiveWorktree: hasActiveWorktree,
      hasRunningRunScript: hasRunningRunScript,
      resolvedSelection: resolvedSelection
    )
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

  // Apply `windowTintColorScheme` here, inside the detail body, so that text
  // and icons painted over the tinted window pick the right luminance — but
  // the surrounding `.toolbar { ... }` items keep the system color scheme so
  // they stay readable in fullscreen, where the titlebar paints with system
  // appearance.
  @ViewBuilder
  private func detailContent(
    repositories: RepositoriesFeature.State,
    loadingInfo: WorktreeLoadingInfo?,
    selectedWorktree: Worktree?,
    selectedSlice: SelectedWorktreeSlice?,
    selectedWorktreeSummaries: [MultiSelectedWorktreeSummary]
  ) -> some View {
    Group {
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
      } else if let failedRepositoryID = repositories.selectedFailedRepositoryID {
        FailedRepositoryDetailView(
          repositoryID: failedRepositoryID,
          failureMessage: repositories.loadFailuresByID[failedRepositoryID]
        ) {
          store.send(.repositories(.requestRemoveFailedRepository(failedRepositoryID)))
        }
      } else if let selectedWorktree, selectedWorktree.isMissing {
        MissingWorktreeDetailView(worktree: selectedWorktree) {
          guard let repositoryID = repositories.sidebarItems[id: selectedWorktree.id]?.repositoryID
          else { return }
          let target = RepositoriesFeature.DeleteWorktreeTarget(
            worktreeID: selectedWorktree.id,
            repositoryID: repositoryID
          )
          store.send(.repositories(.requestDeleteSidebarItems([target])))
        }
      } else if let selectedWorktree {
        let shouldRunSetupScript = selectedSlice?.lifecycle == .pending
        let shouldFocusTerminal = repositories.shouldFocusTerminal(for: selectedWorktree.id)
        WorktreeTerminalTabsView(
          worktree: selectedWorktree,
          manager: terminalManager,
          terminalsStore: store.scope(state: \.terminals, action: \.terminals),
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
    .windowTintColorScheme(manager: terminalManager)
  }

  private func applyFocusedActions<Content: View>(
    content: Content,
    hasActiveWorktree: Bool,
    hasRunningRunScript: Bool,
    resolvedSelection: OpenWorktreeAction?
  ) -> some View {
    content
      .focusedSceneAction(\.openSelectedWorktreeAction, enabled: hasActiveWorktree) {
        store.send(.openSelectedWorktree)
      }
      .focusedSceneAction(\.revealInFinderAction, enabled: hasActiveWorktree) {
        store.send(.revealInFinder)
      }
      .focusedSceneValue(\.openActionSelection, resolvedSelection)
      .focusedSceneAction(\.newTerminalAction, enabled: hasActiveWorktree) {
        store.send(.newTerminal)
      }
      .focusedAction(\.splitTerminalAction, enabled: hasActiveWorktree) { direction in
        store.send(.splitTerminal(direction))
      }
      .focusedAction(\.closeTabAction, enabled: hasActiveWorktree) {
        store.send(.closeTab)
      }
      .focusedAction(\.closeSurfaceAction, enabled: hasActiveWorktree) {
        store.send(.closeSurface)
      }
      .focusedSceneAction(\.startSearchAction, enabled: hasActiveWorktree) {
        store.send(.startSearch)
      }
      .focusedSceneAction(\.searchSelectionAction, enabled: hasActiveWorktree) {
        store.send(.searchSelection)
      }
      .focusedSceneAction(\.navigateSearchNextAction, enabled: hasActiveWorktree) {
        store.send(.navigateSearchNext)
      }
      .focusedSceneAction(\.navigateSearchPreviousAction, enabled: hasActiveWorktree) {
        store.send(.navigateSearchPrevious)
      }
      .focusedSceneAction(\.endSearchAction, enabled: hasActiveWorktree) {
        store.send(.endSearch)
      }
      .focusedSceneAction(\.runScriptAction, enabled: hasActiveWorktree) {
        store.send(.runScript)
      }
      .focusedSceneAction(\.stopRunScriptAction, enabled: hasRunningRunScript) {
        store.send(.stopRunScripts)
      }
  }

  private func selectToolbarNotification(
    _ worktreeID: Worktree.ID,
    _ notification: WorktreeTerminalNotification
  ) {
    store.send(.repositories(.selectWorktree(worktreeID)))
    if let terminalState = terminalManager.stateIfExists(for: worktreeID) {
      _ = terminalState.focusSurface(id: notification.surfaceID)
    }
  }

  /// Toolbar notification button host. Reads `toolbarNotificationGroupsCache`
  /// itself so notification churn invalidates only this leaf. `repositoriesStore`
  /// is optional so previews can mount the host without booting a `Store`.
  fileprivate struct ToolbarNotificationsPopoverButtonHost: View {
    let repositoriesStore: StoreOf<RepositoriesFeature>?
    let terminalManager: WorktreeTerminalManager
    let onSelectNotification: (Worktree.ID, WorktreeTerminalNotification) -> Void

    var body: some View {
      if let repositoriesStore {
        let groups = repositoriesStore.toolbarNotificationGroupsCache
        if !groups.isEmpty {
          let unseenWorktreeCount = groups.reduce(0) { $0 + $1.unseenWorktreeCount }
          ToolbarNotificationsPopoverButton(
            groups: groups,
            unseenWorktreeCount: unseenWorktreeCount,
            onSelectNotification: onSelectNotification,
            onDismissAll: {
              for repositoryGroup in groups {
                for worktreeGroup in repositoryGroup.worktrees {
                  terminalManager.stateIfExists(for: worktreeGroup.id)?.dismissAllNotifications()
                }
              }
            }
          )
        }
      }
    }
  }

  fileprivate struct ScriptMenuIdentity: Hashable {
    let rootURL: URL
    let repoFingerprints: [ScriptFingerprint]
    let globalFingerprints: [ScriptFingerprint]
  }

  fileprivate struct ScriptFingerprint: Hashable {
    let id: UUID
    let displayName: String
    let resolvedSystemImage: String
    let resolvedTintColor: RepositoryColor
    let isCommandBlank: Bool

    init(_ script: ScriptDefinition) {
      id = script.id
      displayName = script.displayName
      resolvedSystemImage = script.resolvedSystemImage
      resolvedTintColor = script.resolvedTintColor
      isCommandBlank = script.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  fileprivate struct WorktreeToolbarState {
    // Folders have no git remote, so the PR payload is scoped to
    // `.git` — this makes "folder with a pull request" unrepresentable.
    enum Kind {
      case git(pullRequest: GithubPullRequest?)
      case folder
    }

    let titleContent: WorktreeToolbarTitleContent
    let rootURL: URL
    let kind: Kind
    let statusToast: RepositoriesFeature.StatusToast?
    let openActionSelection: OpenWorktreeAction
    let repoScripts: [ScriptDefinition]
    let globalScripts: [ScriptDefinition]
    let runningScriptIDs: Set<UUID>

    var isFolder: Bool {
      if case .folder = kind { true } else { false }
    }

    var pullRequest: GithubPullRequest? {
      if case .git(let pullRequest) = kind { pullRequest } else { nil }
    }

    var allScripts: [ScriptDefinition] {
      .merged(repo: repoScripts, global: globalScripts)
    }

    // Drop globals shadowed by repo IDs (handled by `merged`) and globals with
    // empty commands so half-configured entries don't surface in N repo toolbars.
    var visibleGlobalScripts: [ScriptDefinition] {
      Array(allScripts.dropFirst(repoScripts.count))
        .filter { !$0.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    // NSMenu cache key — fingerprint covers only what the toolbar Menu actually renders
    // (display name, icon, tint, has-command). Editing a command body is a no-op for the
    // identity, which avoids per-keystroke menu rebuilds while still catching renames.
    var scriptMenuIdentity: ScriptMenuIdentity {
      ScriptMenuIdentity(
        rootURL: rootURL,
        repoFingerprints: repoScripts.map(ScriptFingerprint.init),
        globalFingerprints: globalScripts.map(ScriptFingerprint.init),
      )
    }

    /// The first `.run`-kind script, if any.
    var primaryScript: ScriptDefinition? {
      allScripts.primaryScript
    }

    /// Whether any `.run`-kind script is currently running.
    var hasRunningRunScript: Bool {
      allScripts.hasRunningRunScript(in: runningScriptIDs)
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
    let terminalManager: WorktreeTerminalManager
    let repositoriesStore: StoreOf<RepositoriesFeature>?
    let onOpenWorktree: (OpenWorktreeAction) -> Void
    let onOpenActionSelectionChanged: (OpenWorktreeAction) -> Void
    let onRevealInFinder: () -> Void
    let onSelectNotification: (Worktree.ID, WorktreeTerminalNotification) -> Void
    let onRunScript: () -> Void
    let onRunNamedScript: (ScriptDefinition) -> Void
    let onStopScript: (ScriptDefinition) -> Void
    let onStopRunScripts: () -> Void
    let onManageRepoScripts: () -> Void
    let onManageGlobalScripts: () -> Void

    var body: some ToolbarContent {
      ToolbarItem(placement: .navigation) {
        WorktreeToolbarTitleView(
          content: toolbarState.titleContent,
          terminalManager: terminalManager
        )
      }
      .sharedBackgroundVisibility(.hidden)

      ToolbarSpacer(.flexible)

      ToolbarItemGroup {
        ToolbarStatusView(
          toast: toolbarState.statusToast,
          pullRequest: toolbarState.pullRequest
        )
        .padding(.horizontal)
        ToolbarNotificationsPopoverButtonHost(
          repositoriesStore: repositoriesStore,
          terminalManager: terminalManager,
          onSelectNotification: onSelectNotification
        )
      }

      ToolbarSpacer(.flexible)

      ToolbarItem {
        openMenu(openActionSelection: toolbarState.openActionSelection)
      }
      ToolbarSpacer(.fixed)

      ToolbarItem {
        ScriptMenu(
          toolbarState: toolbarState,
          onRunScript: onRunScript,
          onRunNamedScript: onRunNamedScript,
          onStopScript: onStopScript,
          onStopRunScripts: onStopRunScripts,
          onManageRepoScripts: onManageRepoScripts,
          onManageGlobalScripts: onManageGlobalScripts
        )
        // Rebuild the NSMenu when any field changes (#280) so renames propagate without a worktree switch.
        .id(toolbarState.scriptMenuIdentity)
        .transaction { $0.animation = nil }
      }
    }

    @ViewBuilder
    private func openMenu(openActionSelection: OpenWorktreeAction) -> some View {
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
              OpenWorktreeActionMenuLabelView(action: action)
            }
            .buttonStyle(.plain)
            .help(openActionHelpText(for: action, isDefault: isDefault))
          }
          Divider()
          Button {
            onRevealInFinder()
          } label: {
            OpenWorktreeActionMenuLabelView(action: .finder)
          }
          .help("Reveal in Finder (\(WorktreeDetailView.resolveShortcutDisplay(for: AppShortcuts.revealInFinder)))")
        } label: {
          OpenWorktreeActionMenuLabelView(action: primarySelection)
        } primaryAction: {
          onOpenWorktree(primarySelection)
        }
        .help(openActionHelpText(for: primarySelection, isDefault: true))
      }
    }

    private func openActionHelpText(for action: OpenWorktreeAction, isDefault: Bool) -> String {
      guard isDefault else { return action.title }
      return "\(action.title) (\(WorktreeDetailView.resolveShortcutDisplay(for: AppShortcuts.openWorktree)))"
    }
  }

  static func makeToolbarTitleContent(
    selectedWorktree: Worktree,
    selectedRow: SelectedWorktreeSlice?,
    repositories: RepositoriesFeature.State,
    hideSubtitleOnMatch: Bool
  ) -> WorktreeToolbarTitleContent {
    let repositoryID = selectedRow?.repositoryID
    let repository = repositoryID.flatMap { repositories.repositories[id: $0] }
    let section = repositoryID.flatMap { repositories.sidebar.sections[$0] }
    let defaultName = repository?.name ?? selectedWorktree.repositoryRootURL.lastPathComponent
    let repositoryName = SidebarDisplayName.resolved(custom: section?.title, fallback: defaultName) ?? defaultName

    if selectedRow?.isFolder == true {
      // Folders use the per-row custom title (matches the sidebar's folder title position).
      let folderName =
        SidebarDisplayName.resolved(custom: selectedRow?.customTitle, fallback: repositoryName) ?? repositoryName
      return .folder(name: folderName, tint: selectedRow?.customTint)
    }

    let worktreeSubtitle: String? = {
      guard let selectedRow else { return nil }
      // Sole default worktree: nothing to disambiguate.
      if selectedRow.isMainWorktree,
        let repository,
        repository.worktrees.count == 1,
        !repositories.pendingWorktrees.contains(where: { $0.repositoryID == repository.id })
      {
        return nil
      }
      // Subtitle stays on the auto-derived disambiguator (sidebarDisplayName) so the chrome shows
      // identity context even when the user picked a custom title for the row.
      let worktreeName = selectedRow.sidebarDisplayName ?? "Default"
      let branchName = selectedWorktree.name
      let branchLastComponent = branchName.split(separator: "/").last.map(String.init) ?? branchName
      if hideSubtitleOnMatch, worktreeName == branchLastComponent { return nil }
      return worktreeName
    }()

    // Top text mirrors the sidebar title: custom override if set, else the literal branch name.
    // `branchName` stays on the real ref so VoiceOver announces "Branch <real-branch>" instead of
    // the user-typed override (which isn't a ref).
    let displayTitle =
      SidebarDisplayName.resolved(
        custom: selectedRow?.customTitle,
        fallback: selectedWorktree.name
      ) ?? selectedWorktree.name

    return .git(
      .init(
        displayTitle: displayTitle,
        branchName: selectedWorktree.name,
        repositoryName: repositoryName,
        repositoryColor: section?.color,
        worktreeSubtitle: worktreeSubtitle,
        worktreeTint: selectedRow?.customTint,
        accent: selectedRow?.accent ?? .default,
        rootURL: selectedWorktree.repositoryRootURL
      )
    )
  }

  private func toolbarKind(
    for selectedWorktree: Worktree,
    selectedRow: SelectedWorktreeSlice?
  ) -> WorktreeToolbarState.Kind {
    guard selectedRow?.isFolder != true else { return .folder }
    guard let pullRequest = selectedRow?.pullRequest else {
      return .git(pullRequest: nil)
    }
    // Only surface the PR when its head branch matches the current
    // worktree, otherwise stale info sticks around after a rename
    // or branch switch.
    let matches = pullRequest.headRefName == nil || pullRequest.headRefName == selectedWorktree.name
    return .git(pullRequest: matches ? pullRequest : nil)
  }

  private func loadingInfo(
    for selectedRow: SelectedWorktreeSlice?,
    selectedWorktreeID: Worktree.ID?,
    repositories: RepositoriesFeature.State
  ) -> WorktreeLoadingInfo? {
    guard let selectedRow else { return nil }
    let repositoryName = repositories.repositoryName(for: selectedRow.repositoryID)
    switch selectedRow.lifecycle {
    case .deleting:
      return WorktreeLoadingInfo(
        name: selectedRow.name,
        repositoryName: repositoryName,
        kind: .removing(isFolder: selectedRow.isFolder)
      )
    case .archiving, .deletingScript:
      // The script runs in a terminal tab, so let the
      // terminal view show through instead of a loading overlay.
      return nil
    case .idle:
      return nil
    case .pending:
      break
    }
    if selectedRow.lifecycle.isPending {
      let pending = repositories.pendingWorktree(for: selectedWorktreeID)
      let progress = pending?.progress
      let displayName = progress?.worktreeName ?? selectedRow.name
      return WorktreeLoadingInfo(
        name: displayName,
        repositoryName: repositoryName,
        kind: .creating(
          WorktreeLoadingInfo.Progress(
            statusTitle: progress?.titleText ?? selectedRow.name,
            statusDetail: progress?.detailText ?? (selectedRow.subtitle ?? ""),
            statusCommand: progress?.commandText,
            statusLines: progress?.liveOutputLines ?? []
          )
        )
      )
    }
    return nil
  }

  static func resolveShortcutDisplay(for shortcut: AppShortcut, fallback: String = "none") -> String {
    @Shared(.settingsFile) var settingsFile
    let display = shortcut.effective(from: settingsFile.global.shortcutOverrides)?.display ?? fallback
    return display.isEmpty ? fallback : display
  }
}

// MARK: - Detail placeholder.

private struct FailedRepositoryDetailView: View {
  let repositoryID: Repository.ID
  let failureMessage: String?
  let requestRemove: () -> Void

  var body: some View {
    let path = URL(fileURLWithPath: repositoryID).standardizedFileURL.path(percentEncoded: false)
    ContentUnavailableView {
      Label("Repository unavailable", systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.pink)
    } description: {
      VStack(spacing: 6) {
        Text("Restore the repository to keep working here, or remove it from Supacode.")
        // Diagnostic surface for the underlying load failure (permission denied,
        // missing dir, etc) without disrupting the uniform layout.
        Text(path)
          .monospaced()
          .textSelection(.enabled)
          .help(failureMessage ?? "")
      }
    } actions: {
      Button(
        "Remove Repository…",
        systemImage: "folder.badge.minus",
        role: .destructive,
        action: requestRemove
      )
      .help("Remove this repository from Supacode. Files on disk are untouched.")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct MissingWorktreeDetailView: View {
  let worktree: Worktree
  let requestDelete: () -> Void

  var body: some View {
    ContentUnavailableView {
      Label("Working directory missing", systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
    } description: {
      VStack(spacing: 6) {
        Text("Restore the directory to keep working here, or delete this worktree to clean up.")
        Text(worktree.workingDirectory.path(percentEncoded: false))
          .monospaced()
          .textSelection(.enabled)
      }
    } actions: {
      Button("Delete Worktree…", systemImage: "trash", role: .destructive, action: requestDelete)
        .help("Delete this worktree from Supacode.")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

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
    ToolbarItem(placement: .navigation) {
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
    .sharedBackgroundVisibility(.hidden)

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
  let kind: SidebarItemFeature.State.Kind
  let name: String
  let repositoryName: String?
}

private struct MultiSelectedWorktreesDetailView: View {
  let rows: [MultiSelectedWorktreeSummary]

  private let visibleRowsLimit = 8

  private var worktreeRows: [MultiSelectedWorktreeSummary] {
    rows.filter { $0.kind == .gitWorktree }
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
          if let repositoryName = row.repositoryName, row.kind == .gitWorktree {
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
  let onManageRepoScripts: () -> Void
  let onManageGlobalScripts: () -> Void

  private var primaryScript: ScriptDefinition? {
    toolbarState.primaryScript
  }

  var body: some View {
    let hasRunning = toolbarState.hasRunningRunScript
    Menu {
      scriptButtons(for: toolbarState.repoScripts)
      let visibleGlobals = toolbarState.visibleGlobalScripts
      if !visibleGlobals.isEmpty {
        if !toolbarState.repoScripts.isEmpty {
          Divider()
        }
        Section("Global") {
          scriptButtons(for: visibleGlobals)
        }
      }
      if !toolbarState.allScripts.isEmpty {
        Divider()
      }
      Button("Manage Repo Scripts…") {
        onManageRepoScripts()
      }
      .help("Open repository settings to manage repo scripts.")
      Button("Manage Global Scripts…") {
        onManageGlobalScripts()
      }
      .help("Open settings to manage global scripts.")
    } label: {
      scriptLabel(hasRunning: hasRunning)
    } primaryAction: {
      if hasRunning {
        onStopRunScripts()
      } else if primaryScript != nil {
        onRunScript()
      } else if toolbarState.repoScripts.isEmpty, !toolbarState.globalScripts.isEmpty {
        onManageGlobalScripts()
      } else {
        onManageRepoScripts()
      }
    }
    .help(primaryHelpText(hasRunning: hasRunning))
  }

  @ViewBuilder
  private func scriptButtons(for scripts: [ScriptDefinition]) -> some View {
    ForEach(scripts) { script in
      let isRunning = toolbarState.runningScriptIDs.contains(script.id)
      let hasCommand = !script.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
      .disabled(!isRunning && !hasCommand)
      .help(scriptButtonHelp(script: script, isRunning: isRunning, hasCommand: hasCommand))
    }
  }

  private func scriptButtonHelp(script: ScriptDefinition, isRunning: Bool, hasCommand: Bool) -> String {
    if isRunning { return "Stop \(script.displayName)." }
    if !hasCommand { return "\"\(script.displayName)\" has no command. Configure it in Settings." }
    return "Run \(script.displayName)."
  }

  @ViewBuilder
  private func scriptLabel(hasRunning: Bool) -> some View {
    let icon = hasRunning ? "stop" : (primaryScript?.resolvedSystemImage ?? "play")
    let label = hasRunning ? "Stop" : (primaryScript?.displayName ?? "Run")
    Label {
      Text(label)
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

  init() {
    toolbarState = WorktreeDetailView.WorktreeToolbarState(
      titleContent: .git(
        .init(
          displayTitle: "feature/toolbar-preview",
          branchName: "feature/toolbar-preview",
          repositoryName: "supacode",
          repositoryColor: .blue,
          worktreeSubtitle: "toolbar-preview",
          worktreeTint: nil,
          accent: .pinned,
          rootURL: URL(fileURLWithPath: "/tmp/preview")
        )
      ),
      rootURL: URL(fileURLWithPath: "/tmp/preview"),
      kind: .git(pullRequest: nil),
      statusToast: nil,
      openActionSelection: .finder,
      repoScripts: [ScriptDefinition(kind: .run, command: "npm run dev")],
      globalScripts: [],
      runningScriptIDs: [],
    )
  }

  var body: some View {
    NavigationStack {
      Text("Worktree Toolbar")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .toolbar {
      WorktreeDetailView.WorktreeToolbarContent(
        toolbarState: toolbarState,
        terminalManager: WorktreeTerminalManager(runtime: GhosttyRuntime()),
        repositoriesStore: nil,
        onOpenWorktree: { _ in },
        onOpenActionSelectionChanged: { _ in },
        onRevealInFinder: {},
        onSelectNotification: { _, _ in },
        onRunScript: {},
        onRunNamedScript: { _ in },
        onStopScript: { _ in },
        onStopRunScripts: {},
        onManageRepoScripts: {},
        onManageGlobalScripts: {}
      )
    }
    .frame(width: 900, height: 160)
  }
}

#Preview("Worktree Toolbar") {
  WorktreeToolbarPreview()
}
