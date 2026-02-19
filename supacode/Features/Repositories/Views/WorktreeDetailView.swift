import AppKit
import ComposableArchitecture
import Sharing
import SwiftUI

struct WorktreeDetailView: View {
  @Bindable var store: StoreOf<AppFeature>
  let terminalManager: WorktreeTerminalManager
  @Environment(CommandKeyObserver.self) private var commandKeyObserver
  @Shared(.appStorage("worktreeDiffPanelWidth")) private var worktreeDiffPanelWidth = 420.0
  @Shared(.appStorage("worktreeDiffPanelIsVisible")) private var isWorktreeDiffPanelVisible = true
  @State private var diffPanelDragStartWidth: Double?
  private static let minDiffPanelWidth = 280.0
  private static let maxDiffPanelWidth = 960.0

  var body: some View {
    detailBody(state: store.state)
  }

  private func detailBody(state: AppFeature.State) -> some View {
    let repositories = state.repositories
    let selectedRow = repositories.selectedRow(for: repositories.selectedWorktreeID)
    let selectedWorktree = repositories.worktree(for: repositories.selectedWorktreeID)
    let loadingInfo = loadingInfo(
      for: selectedRow,
      selectedWorktreeID: repositories.selectedWorktreeID,
      repositories: repositories
    )
    let hasActiveWorktree = selectedWorktree != nil && loadingInfo == nil
    let openActionSelection = state.openActionSelection
    let runScriptEnabled = hasActiveWorktree
    let runScriptIsRunning = selectedWorktree.flatMap { state.runScriptStatusByWorktreeID[$0.id] } == true
    let isDiffPanelVisible = hasActiveWorktree && isWorktreeDiffPanelVisible
    let notificationGroups = repositories.toolbarNotificationGroups(terminalManager: terminalManager)
    let unseenNotificationWorktreeCount = notificationGroups.reduce(0) { count, repository in
      count + repository.unseenWorktreeCount
    }
    let content = detailContent(
      repositories: repositories,
      loadingInfo: loadingInfo,
      selectedWorktree: selectedWorktree,
      isDiffPanelVisible: isDiffPanelVisible
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
          isDiffPanelVisible: isDiffPanelVisible,
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
          onToggleDiffPanel: {
            $isWorktreeDiffPanelVisible.withLock { value in
              value.toggle()
            }
          },
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

  @ViewBuilder
  private func detailContent(
    repositories: RepositoriesFeature.State,
    loadingInfo: WorktreeLoadingInfo?,
    selectedWorktree: Worktree?,
    isDiffPanelVisible: Bool
  ) -> some View {
    if repositories.isShowingArchivedWorktrees {
      ArchivedWorktreesDetailView(
        store: store.scope(state: \.repositories, action: \.repositories)
      )
    } else if let loadingInfo {
      WorktreeLoadingView(info: loadingInfo)
    } else if let selectedWorktree {
      let shouldRunSetupScript = repositories.pendingSetupScriptWorktreeIDs.contains(selectedWorktree.id)
      let shouldFocusTerminal = repositories.shouldFocusTerminal(for: selectedWorktree.id)
      let terminalContent = WorktreeTerminalTabsView(
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
      .task(id: "\(selectedWorktree.id)-\(isDiffPanelVisible)") {
        guard isDiffPanelVisible else {
          return
        }
        store.send(.repositories(.refreshWorktreeDiff(worktreeID: selectedWorktree.id, debounce: false)))
      }
      if isDiffPanelVisible {
        HStack(spacing: 0) {
          terminalContent
          diffPanelResizeHandle
          WorktreeDiffPanelView(
            state: repositories.worktreeDiffPanel,
            selectedWorktreeID: selectedWorktree.id
          )
          .frame(width: clampedWorktreeDiffPanelWidth)
          .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        terminalContent
      }
    } else {
      EmptyStateView(store: store.scope(state: \.repositories, action: \.repositories))
    }
  }

  private var clampedWorktreeDiffPanelWidth: CGFloat {
    let clampedWidth = min(
      Self.maxDiffPanelWidth,
      max(Self.minDiffPanelWidth, worktreeDiffPanelWidth)
    )
    return CGFloat(clampedWidth)
  }

  private var diffPanelResizeHandle: some View {
    ZStack {
      Divider()
      Color.clear
        .frame(width: 8)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(
          DragGesture(minimumDistance: 0)
            .onChanged { value in
              if diffPanelDragStartWidth == nil {
                diffPanelDragStartWidth = Double(clampedWorktreeDiffPanelWidth)
              }
              guard let startWidth = diffPanelDragStartWidth else {
                return
              }
              let nextWidth = min(
                Self.maxDiffPanelWidth,
                max(Self.minDiffPanelWidth, startWidth - value.translation.width)
              )
              $worktreeDiffPanelWidth.withLock { current in
                current = nextWidth
              }
            }
            .onEnded { _ in
              diffPanelDragStartWidth = nil
            }
        )
    }
    .frame(width: 8)
    .frame(maxHeight: .infinity)
  }

  private func applyFocusedActions<Content: View>(
    content: Content,
    actions: FocusedActions
  ) -> some View {
    content
      .focusedSceneValue(\.openSelectedWorktreeAction, actions.openSelectedWorktree)
      .focusedSceneValue(\.newTerminalAction, actions.newTerminal)
      .focusedSceneValue(\.closeTabAction, actions.closeTab)
      .focusedSceneValue(\.closeSurfaceAction, actions.closeSurface)
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
    let isDiffPanelVisible: Bool
    let runScriptEnabled: Bool
    let runScriptIsRunning: Bool

    var runScriptHelpText: String {
      "Run Script (\(AppShortcuts.runScript.display))"
    }

    var stopRunScriptHelpText: String {
      "Stop Script (\(AppShortcuts.stopRunScript.display))"
    }

    var toggleDiffPanelHelpText: String {
      isDiffPanelVisible ? "Hide Diff Panel" : "Show Diff Panel"
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
    let onToggleDiffPanel: () -> Void
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
      ToolbarItem {
        Button {
          onToggleDiffPanel()
        } label: {
          Image(systemName: toolbarState.isDiffPanelVisible ? "rectangle.righthalf.inset.filled" : "rectangle")
        }
        .help(toolbarState.toggleDiffPanelHelpText)
      }
      ToolbarSpacer(.fixed)

      if toolbarState.runScriptIsRunning || toolbarState.runScriptEnabled {
        ToolbarItem {
          RunScriptToolbarButton(
            isRunning: toolbarState.runScriptIsRunning,
            isEnabled: toolbarState.runScriptEnabled,
            runHelpText: toolbarState.runScriptHelpText,
            stopHelpText: toolbarState.stopRunScriptHelpText,
            runShortcut: AppShortcuts.runScript.display,
            stopShortcut: AppShortcuts.stopRunScript.display,
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
          shortcutHint: showExtras ? AppShortcuts.openFinder.display : nil
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

    private func openActionHelpText(for action: OpenWorktreeAction, isDefault: Bool) -> String {
      isDefault
        ? "\(action.title) (\(AppShortcuts.openFinder.display))"
        : action.title
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
        statusLines: []
      )
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
        statusLines: progress?.liveOutputLines ?? []
      )
    }
    return nil
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
      isDiffPanelVisible: true,
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
        onToggleDiffPanel: {},
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
