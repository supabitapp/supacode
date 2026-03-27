import AppKit
import ComposableArchitecture
import Sharing
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
    let hasActiveWorktree =
      selectedWorktree != nil
      && loadingInfo == nil
      && !showsMultiSelectionSummary
    let openActionSelection = state.openActionSelection
    let runScriptEnabled = hasActiveWorktree
    let runScriptIsRunning = selectedWorktree.flatMap { state.runScriptStatusByWorktreeID[$0.id] } == true
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
      if hasActiveWorktree, let selectedWorktree {
        let pullRequest = repositories.worktreeInfo(for: selectedWorktree.id)?.pullRequest
        let matchesBranch =
          if let pullRequest {
            pullRequest.headRefName == nil || pullRequest.headRefName == selectedWorktree.name
          } else {
            false
          }
        let toolbarState = WorktreeToolbarState(
          branchName: selectedWorktree.name,
          statusToast: repositories.statusToast,
          pullRequest: matchesBranch ? pullRequest : nil,
          notificationGroups: notificationGroups,
          unseenNotificationWorktreeCount: unseenNotificationWorktreeCount,
          openActionSelection: openActionSelection,
          showExtras: commandKeyObserver.isPressed,
          runScriptEnabled: runScriptEnabled,
          runScriptIsRunning: runScriptIsRunning
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
          onCopyPath: {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(selectedWorktree.workingDirectory.path, forType: .string)
          },
          onSelectNotification: selectToolbarNotification,
          onDismissAllNotifications: { dismissAllToolbarNotifications(in: notificationGroups) },
          onRunScript: { store.send(.runScript) },
          onStopRunScript: { store.send(.stopRunScript) }
        )
      }
    }
    let actions = makeFocusedActions(
      hasActiveWorktree: hasActiveWorktree,
      runScriptEnabled: runScriptEnabled,
      runScriptIsRunning: runScriptIsRunning
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
      .onAppear {
        if shouldFocusTerminal {
          store.send(.repositories(.consumeTerminalFocus(selectedWorktree.id)))
        }
      }
    } else {
      EmptyStateView(store: store.scope(state: \.repositories, action: \.repositories))
    }
  }

  private func applyFocusedActions<Content: View>(
    content: Content,
    actions: FocusedActions
  ) -> some View {
    content
      .focusedSceneValue(\.openSelectedWorktreeAction, actions.openSelectedWorktree)
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
    runScriptEnabled: Bool,
    runScriptIsRunning: Bool
  ) -> FocusedActions {
    func action(_ appAction: AppFeature.Action) -> (() -> Void)? {
      hasActiveWorktree ? { store.send(appAction) } : nil
    }
    return FocusedActions(
      openSelectedWorktree: action(.openSelectedWorktree),
      newTerminal: action(.newTerminal),
      closeTab: action(.closeTab),
      closeSurface: action(.closeSurface),
      startSearch: action(.startSearch),
      searchSelection: action(.searchSelection),
      navigateSearchNext: action(.navigateSearchNext),
      navigateSearchPrevious: action(.navigateSearchPrevious),
      endSearch: action(.endSearch),
      runScript: runScriptEnabled ? { store.send(.runScript) } : nil,
      stopRunScript: runScriptIsRunning ? { store.send(.stopRunScript) } : nil
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
    let branchName: String
    let statusToast: RepositoriesFeature.StatusToast?
    let pullRequest: GithubPullRequest?
    let notificationGroups: [ToolbarNotificationRepositoryGroup]
    let unseenNotificationWorktreeCount: Int
    let openActionSelection: OpenWorktreeAction
    let showExtras: Bool
    let runScriptEnabled: Bool
    let runScriptIsRunning: Bool

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
    let onCopyPath: () -> Void
    let onSelectNotification: (Worktree.ID, WorktreeTerminalNotification) -> Void
    let onDismissAllNotifications: () -> Void
    let onRunScript: () -> Void
    let onStopRunScript: () -> Void

    var body: some ToolbarContent {
      ToolbarItem {
        WorktreeDetailTitleView(
          branchName: toolbarState.branchName,
          onSubmit: onRenameBranch
        )
      }

      ToolbarSpacer(.flexible)

      ToolbarItemGroup {
        ToolbarStatusView(
          toast: toolbarState.statusToast,
          pullRequest: toolbarState.pullRequest
        )
        .padding(.horizontal)
      }

      if !toolbarState.notificationGroups.isEmpty {
        ToolbarSpacer(.fixed)
        ToolbarItemGroup {
          ToolbarNotificationsPopoverButton(
            groups: toolbarState.notificationGroups,
            unseenWorktreeCount: toolbarState.unseenNotificationWorktreeCount,
            onSelectNotification: onSelectNotification,
            onDismissAll: onDismissAllNotifications
          )
        }
      }

      ToolbarSpacer(.flexible)

      ToolbarItemGroup {
        openMenu(
          openActionSelection: toolbarState.openActionSelection,
          showExtras: toolbarState.showExtras
        )
      }
      ToolbarSpacer(.fixed)

      if toolbarState.runScriptIsRunning || toolbarState.runScriptEnabled {
        ToolbarItem {
          RunScriptToolbarButton(
            isRunning: toolbarState.runScriptIsRunning,
            isEnabled: toolbarState.runScriptEnabled,
            runHelpText: toolbarState.runScriptHelpText,
            stopHelpText: toolbarState.stopRunScriptHelpText,
            runShortcut: shortcutDisplay(for: AppShortcuts.runScript, fallback: ""),
            stopShortcut: shortcutDisplay(for: AppShortcuts.stopRunScript, fallback: ""),
            runAction: onRunScript,
            stopAction: onStopRunScript
          )
        }
      }

    }

    @ViewBuilder
    private func openMenu(openActionSelection: OpenWorktreeAction, showExtras: Bool) -> some View {
      let availableActions = OpenWorktreeAction.availableCases
      let resolvedOpenActionSelection = OpenWorktreeAction.availableSelection(openActionSelection)
      Button {
        onOpenWorktree(resolvedOpenActionSelection)
      } label: {
        OpenWorktreeActionMenuLabelView(
          action: resolvedOpenActionSelection,
          shortcutHint: showExtras ? shortcutDisplay(for: AppShortcuts.openFinder, fallback: "") : nil
        )
      }
      .help(openActionHelpText(for: resolvedOpenActionSelection, isDefault: true))

      Menu {
        ForEach(availableActions) { action in
          let isDefault = action == resolvedOpenActionSelection
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
        Button("Copy Path") {
          onCopyPath()
        }
        .help("Copy path")
      } label: {
        Image(systemName: "chevron.down")
          .font(.caption2)
          .accessibilityLabel("Open in menu")
      }
      .imageScale(.small)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Open in...")

    }

    private func shortcutDisplay(for shortcut: AppShortcut, fallback: String = "none") -> String {
      @Shared(.settingsFile) var settingsFile
      return shortcut.effective(from: settingsFile.global.shortcutOverrides)?.display ?? fallback
    }

    private func openActionHelpText(for action: OpenWorktreeAction, isDefault: Bool) -> String {
      guard isDefault else { return action.title }
      return "\(action.title) (\(shortcutDisplay(for: AppShortcuts.openFinder)))"
    }
  }

  private func loadingInfo(
    for selectedRow: WorktreeRowModel?,
    selectedWorktreeID: Worktree.ID?,
    repositories: RepositoriesFeature.State
  ) -> WorktreeLoadingInfo? {
    guard let selectedRow else { return nil }
    let repositoryName = repositories.repositoryName(for: selectedRow.repositoryID)
    if selectedRow.isDeleting {
      return WorktreeLoadingInfo(
        name: selectedRow.name,
        repositoryName: repositoryName,
        state: .removing,
        statusTitle: nil,
        statusDetail: nil,
        statusCommand: nil,
        statusLines: []
      )
    }
    if selectedRow.isArchiving {
      // The archive script runs in a terminal tab, so let the
      // terminal view show through instead of a loading overlay.
      return nil
    }
    if selectedRow.isPending {
      let pending = repositories.pendingWorktree(for: selectedWorktreeID)
      let progress = pending?.progress
      let displayName = progress?.worktreeName ?? selectedRow.name
      return WorktreeLoadingInfo(
        name: displayName,
        repositoryName: repositoryName,
        state: .creating,
        statusTitle: progress?.titleText ?? selectedRow.name,
        statusDetail: progress?.detailText ?? selectedRow.detail,
        statusCommand: progress?.commandText,
        statusLines: progress?.liveOutputLines ?? []
      )
    }
    return nil
  }
}

private struct MultiSelectedWorktreeSummary: Identifiable {
  let id: Worktree.ID
  let name: String
  let repositoryName: String?
}

private struct MultiSelectedWorktreesDetailView: View {
  let rows: [MultiSelectedWorktreeSummary]

  private let visibleRowsLimit = 8

  var body: some View {
    let archiveShortcut = KeyboardShortcut(.delete, modifiers: .command).display
    let deleteShortcut = KeyboardShortcut(.delete, modifiers: [.command, .shift]).display
    VStack(alignment: .leading, spacing: 16) {
      Text("\(rows.count) worktrees selected")
        .font(.title3)
      VStack(alignment: .leading, spacing: 8) {
        ForEach(Array(rows.prefix(visibleRowsLimit))) { row in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(row.name)
              .lineLimit(1)
            if let repositoryName = row.repositoryName {
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
      }
      Divider()
      VStack(alignment: .leading, spacing: 6) {
        Text("Available actions")
          .font(.headline)
        Text("Archive selected (\(archiveShortcut))")
        Text("Delete selected (\(deleteShortcut))")
        Text("Right-click any selected worktree to apply actions to all selected worktrees.")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      Spacer(minLength: 0)
    }
    .padding(20)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

private struct RunScriptToolbarButton: View {
  let isRunning: Bool
  let isEnabled: Bool
  let runHelpText: String
  let stopHelpText: String
  let runShortcut: String
  let stopShortcut: String
  let runAction: () -> Void
  let stopAction: () -> Void
  @Environment(CommandKeyObserver.self) private var commandKeyObserver

  var body: some View {
    if isRunning {
      button(
        config: RunScriptButtonConfig(
          title: "Stop",
          systemImage: "stop.fill",
          helpText: stopHelpText,
          shortcut: stopShortcut,
          isEnabled: true,
          action: stopAction
        ))
    } else {
      button(
        config: RunScriptButtonConfig(
          title: "Run",
          systemImage: "play.fill",
          helpText: runHelpText,
          shortcut: runShortcut,
          isEnabled: isEnabled,
          action: runAction
        ))
    }
  }

  @ViewBuilder
  private func button(config: RunScriptButtonConfig) -> some View {
    Button {
      config.action()
    } label: {
      HStack(spacing: 6) {
        Image(systemName: config.systemImage)
          .accessibilityHidden(true)
        Text(config.title)

        if commandKeyObserver.isPressed {
          Text(config.shortcut)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .font(.caption)
    .help(config.helpText)
    .disabled(!config.isEnabled)
  }

  private struct RunScriptButtonConfig {
    let title: String
    let systemImage: String
    let helpText: String
    let shortcut: String
    let isEnabled: Bool
    let action: () -> Void
  }
}

@MainActor
private struct WorktreeToolbarPreview: View {
  private let toolbarState: WorktreeDetailView.WorktreeToolbarState
  private let commandKeyObserver: CommandKeyObserver

  init() {
    toolbarState = WorktreeDetailView.WorktreeToolbarState(
      branchName: "feature/toolbar-preview",
      statusToast: nil,
      pullRequest: nil,
      notificationGroups: [],
      unseenNotificationWorktreeCount: 0,
      openActionSelection: .finder,
      showExtras: false,
      runScriptEnabled: true,
      runScriptIsRunning: false
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
        onCopyPath: {},
        onSelectNotification: { _, _ in },
        onDismissAllNotifications: {},
        onRunScript: {},
        onStopRunScript: {}
      )
    }
    .environment(commandKeyObserver)
    .frame(width: 900, height: 160)
  }
}

#Preview("Worktree Toolbar") {
  WorktreeToolbarPreview()
}
