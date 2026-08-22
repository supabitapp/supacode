import AppKit
import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

/// Single inspector column whose content switches on the active pane.
struct WorktreeStatusInspectorContainer: View {
  let pane: WorktreeInspectorPane
  let isFolder: Bool
  let isCheckingPullRequest: Bool
  let pullRequest: ForgePullRequest?
  let repositoriesStore: StoreOf<RepositoriesFeature>
  let capabilities: ForgeCapabilities
  let terminalManager: WorktreeTerminalManager
  let fileOpenActions: [OpenWorktreeAction]
  let resolvedOpenAction: OpenWorktreeAction?
  let onSelectNotification: (Worktree.ID, WorktreeTerminalNotification) -> Void
  let onPullRequestAction: (RepositoriesFeature.PullRequestAction) -> Void
  let onOpenFile: (URL, OpenWorktreeAction?) -> Void
  let onActivateFile: (URL) -> Void

  @Shared(.settingsFile) private var settingsFile

  var body: some View {
    Group {
      switch pane {
      case .git:
        WorktreeGitInspectorView(
          pullRequest: pullRequest,
          isFolder: isFolder,
          isCheckingPullRequest: isCheckingPullRequest,
          capabilities: capabilities,
          onPullRequestAction: onPullRequestAction
        )
      case .files:
        WorktreeFilesInspectorView(
          store: repositoriesStore.scope(state: \.fileExplorer, action: \.fileExplorer),
          fileOpenActions: fileOpenActions,
          resolvedOpenAction: resolvedOpenAction,
          onOpenFile: onOpenFile,
          onActivateFile: onActivateFile
        )
      case .notifications:
        WorktreeNotificationsInspectorView(
          repositoriesStore: repositoriesStore,
          terminalManager: terminalManager,
          onSelectNotification: onSelectNotification
        )
      }
    }
    // The panes are Forms of implicit-font labels (LabeledContent, checks,
    // actions); raise the base font so they scale like the explicit chrome.
    .appChromeBaseFont(settingsFile.global.chromeTextSize)
    .inspectorForcedAppearance(terminalManager.surfaceBackgroundColorScheme())
  }
}

/// Forces the inspector subtree to the terminal background's appearance so its
/// cards and controls match the chrome, not the app appearance. Set on the host
/// of `.background` to preserve the SwiftUI environment (no re-hosting).
private struct InspectorForcedAppearance: NSViewRepresentable {
  let colorScheme: ColorScheme

  func makeNSView(context: Context) -> NSView { NSView() }

  func updateNSView(_ nsView: NSView, context: Context) {
    let name: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua
    guard nsView.superview?.appearance?.name != name else { return }
    nsView.superview?.appearance = NSAppearance(named: name)
  }
}

extension View {
  fileprivate func inspectorForcedAppearance(_ colorScheme: ColorScheme) -> some View {
    background(InspectorForcedAppearance(colorScheme: colorScheme))
  }
}

// MARK: - Git / Pull request pane

/// Inspector pane mirroring the pull-request popover, re-laid out as a grouped
/// `Form` so it reads cleanly in a narrow inspector column.
struct WorktreeGitInspectorView: View {
  let pullRequest: ForgePullRequest?
  let isFolder: Bool
  let isCheckingPullRequest: Bool
  let capabilities: ForgeCapabilities
  let onPullRequestAction: (RepositoriesFeature.PullRequestAction) -> Void

  var body: some View {
    Group {
      if !isFolder, let pullRequest {
        GitInspectorContent(
          pullRequest: pullRequest,
          capabilities: capabilities,
          onPullRequestAction: onPullRequestAction
        )
      } else {
        Color.clear
      }
    }
    // The header bar sits only over the pull-request content, so the form scrolls
    // under it for the native top blur; the empty/checking states reserve no bar.
    .safeAreaBar(edge: .top) {
      if !isFolder, let pullRequest {
        GitInspectorHeader(pullRequest: pullRequest, vocabulary: capabilities.vocabulary)
      }
    }
    // Empty states as a background so they fill the whole pane (past the safe
    // area) instead of being offset by the reserved bar.
    .background {
      GitInspectorEmptyState(
        isFolder: isFolder,
        hasPullRequest: pullRequest != nil,
        isCheckingPullRequest: isCheckingPullRequest,
        vocabulary: capabilities.vocabulary
      )
    }
  }
}

/// The git pane's empty and loading states, rendered behind the content so they
/// center in the whole pane. Renders nothing once there's a pull request.
private struct GitInspectorEmptyState: View {
  let isFolder: Bool
  let hasPullRequest: Bool
  let isCheckingPullRequest: Bool
  let vocabulary: ForgeVocabulary

  var body: some View {
    if isFolder {
      ContentUnavailableView(
        "Not a Git Repository",
        systemImage: "folder",
        description: Text("This folder isn't a git repository.")
      )
    } else if !hasPullRequest {
      if isCheckingPullRequest {
        VStack(spacing: 10) {
          ProgressView()
          Text("Checking for pull request…")
            .foregroundStyle(.secondary)
        }
      } else {
        ContentUnavailableView(
          "No \(vocabulary.noun)",
          systemImage: "arrow.trianglehead.branch",
          description: Text("This worktree has no open \(vocabulary.noun.lowercased()).")
        )
      }
    }
  }
}

/// Pull-request pane header, shown only over the pull-request content. The Open
/// in Browser affordance appears when the pull request has a URL.
private struct GitInspectorHeader: View {
  let pullRequest: ForgePullRequest
  let vocabulary: ForgeVocabulary
  @Environment(\.openURL) private var openURL
  @Environment(\.analyticsClient) private var analyticsClient

  var body: some View {
    HStack {
      Text(vocabulary.noun)
        .appFont(.headline)
      Spacer()
      if let url = URL(string: pullRequest.url) {
        Button {
          analyticsClient.capture("github_pr_opened", nil)
          openURL(url)
        } label: {
          Text("Open in Browser \u{2197}")
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal)
    .padding(.vertical)
  }
}

private struct GitInspectorContent: View {
  let pullRequest: ForgePullRequest
  let capabilities: ForgeCapabilities
  let onPullRequestAction: (RepositoriesFeature.PullRequestAction) -> Void

  var body: some View {
    let checks = pullRequest.statusCheckRollup?.checks ?? []
    let breakdown = PullRequestCheckBreakdown(checks: checks)
    let sortedChecks = Self.sortedChecks(checks)
    let readiness = PullRequestMergeReadiness(pullRequest: pullRequest)
    let mergeQueueStatus = PullRequestMergeQueueStatus(pullRequest: pullRequest)
    let badge = PullRequestBadgeStyle.style(
      state: pullRequest.state,
      number: pullRequest.number,
      isQueued: mergeQueueStatus != nil,
      numberSigil: pullRequest.numberSigil
    )

    Form {
      Section {
        LabeledContent("Author", value: pullRequest.authorLogin ?? "Someone")
        LabeledContent("Commits", value: (pullRequest.commitsCount ?? 0).formatted())
        if let additions = pullRequest.additions, let deletions = pullRequest.deletions {
          LabeledContent("Changes") {
            HStack(spacing: 6) {
              Text("+\(additions.formatted())").foregroundStyle(.green)
              Text("-\(deletions.formatted())").foregroundStyle(.red)
            }
          }
        }
        if readiness.isConflicting {
          Label {
            Text("Merge Conflicts")
          } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(.red)
          }
        }
      } header: {
        VStack(alignment: .leading, spacing: 6) {
          if let badge {
            PullRequestBadgeView(
              text: pullRequest.isDraft ? "DRAFT" : badge.text,
              color: badge.color)
          }
          Text(pullRequest.title)
            .appFont(.headline)
            .textSelection(.enabled)
          Text(
            "`\(pullRequest.baseRefName ?? "base")` ← `\(pullRequest.headRefName ?? "branch")`"
          )
          .appFont(.subheadline)
          .monospaced()
          .foregroundStyle(.secondary)
        }
        .textCase(nil)
        .padding(.top, 10)
        .padding(.bottom, 6)
      }

      if let mergeQueueStatus {
        Section {
          PullRequestMergeQueueRow(status: mergeQueueStatus)
        }
      }

      PullRequestActionsSection(
        pullRequest: pullRequest,
        breakdown: breakdown,
        capabilities: capabilities,
        onPullRequestAction: onPullRequestAction
      )

      if breakdown.total > 0 {
        Section("Checks") {
          HStack(spacing: 8) {
            PullRequestChecksRingView(breakdown: breakdown)
            Text(breakdown.summaryText)
              .foregroundStyle(.secondary)
              .appFont(.callout)
          }
          ForEach(sortedChecks, id: \.self) { check in
            CheckRow(check: check)
          }
        }
      }
    }
    .formStyle(.grouped)
    // Let the window's terminal background (set in WindowChromeApplier) show through.
    .scrollContentBackground(.hidden)
    .scrollEdgeEffectStyle(.soft, for: .all)
  }

  private static func sortedChecks(_ checks: [ForgePullRequestStatusCheck])
    -> [ForgePullRequestStatusCheck]
  {
    checks.sorted {
      let left = sortRank(for: $0.checkState)
      let right = sortRank(for: $1.checkState)
      if left == right {
        return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
      }
      return left < right
    }
  }

  private static func sortRank(for state: ForgePullRequestCheckState) -> Int {
    switch state {
    case .failure: 0
    case .inProgress: 1
    case .expected: 2
    case .skipped: 3
    case .success: 4
    }
  }
}

/// Pull-request actions gated the same way as the command palette (mark ready
/// for drafts, merge when ready, CI helpers when failing, close while open).
private struct PullRequestActionsSection: View {
  let pullRequest: ForgePullRequest
  let breakdown: PullRequestCheckBreakdown
  let capabilities: ForgeCapabilities
  let onPullRequestAction: (RepositoriesFeature.PullRequestAction) -> Void

  var body: some View {
    let vocabulary = capabilities.vocabulary
    let isOpen = pullRequest.state == .open
    let isDraft = pullRequest.isDraft
    // Permissive on purpose: merge stays offered while mergeability is still
    // computing; only a confirmed block hides it.
    let canMerge = isOpen && !isDraft && PullRequestMergeReadiness(pullRequest: pullRequest).blockingReason == nil
    let hasFailingChecks = breakdown.failed > 0
    let checks = pullRequest.statusCheckRollup?.checks ?? []
    let hasFailingCheckWithDetails = checks.contains { $0.checkState == .failure && $0.detailsUrl != nil }

    if isOpen {
      Section("Actions") {
        if canMerge {
          PullRequestActionRow(
            title: "Merge \(vocabulary.noun)", icon: .asset(SidebarPullRequestIcon.merged.assetName)
          ) {
            onPullRequestAction(.merge)
          }
        }
        if isDraft, capabilities.canMarkReady {
          PullRequestActionRow(title: "Mark Ready for Review", icon: .asset(SidebarPullRequestIcon.open.assetName)) {
            onPullRequestAction(.markReadyForReview)
          }
        }
        if hasFailingChecks {
          if hasFailingCheckWithDetails {
            PullRequestActionRow(title: "Copy Failing Job URL", icon: .symbol("link")) {
              onPullRequestAction(.copyFailingJobURL)
            }
          }
          if capabilities.canCopyCIFailureLogs {
            PullRequestActionRow(title: "Copy CI Failure Logs", icon: .symbol("doc.on.clipboard")) {
              onPullRequestAction(.copyCiFailureLogs)
            }
          }
          if capabilities.canRerunChecks {
            PullRequestActionRow(title: "Re-run Failed Jobs", icon: .symbol("arrow.clockwise")) {
              onPullRequestAction(.rerunFailedJobs)
            }
          }
          if hasFailingCheckWithDetails {
            PullRequestActionRow(title: "Open Failing Check Details", icon: .symbol("arrow.up.right.square")) {
              onPullRequestAction(.openFailingCheckDetails)
            }
          }
        }
        PullRequestActionRow(
          title: "Close \(vocabulary.noun)",
          icon: .asset(SidebarPullRequestIcon.closed.assetName),
          isDestructive: true
        ) {
          onPullRequestAction(.close)
        }
      }
    }
  }
}

/// A pull-request action form row. Uses the app's git marks for lifecycle
/// actions (merge / close / ready) and SF Symbols for the CI helpers.
private struct PullRequestActionRow: View {
  enum Icon {
    case symbol(String)
    case asset(String)
  }

  let title: String
  let icon: Icon
  var isDestructive = false
  let action: () -> Void

  var body: some View {
    Button(role: isDestructive ? .destructive : nil, action: action) {
      Label {
        Text(title)
      } icon: {
        switch icon {
        case .symbol(let name):
          Image(systemName: name)
        case .asset(let name):
          Image(name)
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 14, height: 14)
        }
      }
      .foregroundStyle(isDestructive ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
      .contentShape(.rect)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .buttonStyle(.plain)
    .help(title)
  }
}

private struct CheckRow: View {
  let check: ForgePullRequestStatusCheck
  @Environment(\.openURL) private var openURL
  @Environment(\.analyticsClient) private var analyticsClient

  var body: some View {
    let style = PullRequestCheckStatusStyle(state: check.checkState)
    let url = check.detailsUrl.flatMap(URL.init(string:))
    if let url {
      Button {
        analyticsClient.capture("github_ci_check_opened", nil)
        openURL(url)
      } label: {
        CheckRowLabel(check: check, style: style)
          .contentShape(.rect)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .buttonStyle(.plain)
      .help("Open check details on GitHub.")
    } else {
      CheckRowLabel(check: check, style: style)
    }
  }
}

private struct CheckRowLabel: View {
  let check: ForgePullRequestStatusCheck
  let style: PullRequestCheckStatusStyle

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: style.symbol)
        .foregroundStyle(style.color)
        .accessibilityHidden(true)
      Text(check.displayName)
        .lineLimit(1)
      Spacer()
      Text(style.label)
        .appFont(.caption)
        .foregroundStyle(.secondary)
    }
  }
}

private struct PullRequestMergeQueueRow: View {
  let status: PullRequestMergeQueueStatus

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 6) {
        Image("git-merge-queue")
          .renderingMode(.template)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 14, height: 14)
          .foregroundStyle(.brown)
          .accessibilityHidden(true)
        Text(status.summary)
      }
      if let detail = status.detail {
        Text(detail)
          .appFont(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Notifications pane

/// Inspector pane for worktree notifications. Reads the caches in its own body
/// so churn invalidates only this pane; applies the scope and read filter here.
struct WorktreeNotificationsInspectorView: View {
  let repositoriesStore: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager
  let onSelectNotification: (Worktree.ID, WorktreeTerminalNotification) -> Void

  @Shared(.settingsFile) private var settingsFile

  var body: some View {
    let scope = settingsFile.global.notificationScope
    let isGrouped = settingsFile.global.notificationsGroupedByWorktree
    let unreadOnly = settingsFile.global.notificationsUnreadOnly
    let selectedWorktreeID = repositoriesStore.selectedWorktreeID
    let groups = repositoriesStore.toolbarNotificationGroupsCache
    let allItems = repositoriesStore.toolbarNotificationItemsCache
    let items = NotificationInspectorList.visibleItems(
      allItems, scope: scope, selectedWorktreeID: selectedWorktreeID, unreadOnly: unreadOnly
    )
    let groupedItems =
      isGrouped
      ? NotificationInspectorList.visibleGroups(
        groups, scope: scope, selectedWorktreeID: selectedWorktreeID, unreadOnly: unreadOnly)
      : []
    let prunedCount = NotificationInspectorList.prunedUnreadCount(
      groups: groups, scope: scope, selectedWorktreeID: selectedWorktreeID
    )
    let hasNotificationsAnywhere =
      !allItems.isEmpty
      || NotificationInspectorList.prunedUnreadCount(groups: groups, scope: .all, selectedWorktreeID: nil) > 0
    let actionableWorktreeIDs = NotificationInspectorList.actionableWorktreeIDs(
      groups: groups, scope: scope, selectedWorktreeID: selectedWorktreeID
    )

    NotificationsInspectorContent(
      items: items,
      groupedItems: groupedItems,
      isGrouped: isGrouped,
      scope: scope,
      unreadOnly: unreadOnly,
      selectedWorktreeID: selectedWorktreeID,
      prunedCount: prunedCount,
      hasNotificationsAnywhere: hasNotificationsAnywhere,
      onClearFilters: {
        $settingsFile.withLock {
          $0.global.notificationScope = .all
          $0.global.notificationsUnreadOnly = false
        }
      },
      onSelectNotification: onSelectNotification,
      onMarkRead: { worktreeID, notificationID in
        terminalManager.markNotificationRead(worktreeID: worktreeID, notificationID: notificationID)
      },
      onDismiss: { worktreeID, notificationID in
        terminalManager.dismissNotification(worktreeID: worktreeID, notificationID: notificationID)
      },
      onMarkAllRead: {
        for worktreeID in actionableWorktreeIDs {
          terminalManager.hostIfExists(for: worktreeID)?.markAllNotificationsRead()
        }
      },
      onDismissAll: {
        for worktreeID in actionableWorktreeIDs {
          let host = terminalManager.hostIfExists(for: worktreeID)
          // Unread-only view dismisses only what it shows; read entries stay.
          if unreadOnly {
            host?.dismissUnreadNotifications()
          } else {
            host?.dismissAllNotifications()
          }
        }
      }
    )
  }
}

private struct NotificationsInspectorContent: View {
  let items: [FlatNotificationItem]
  let groupedItems: [GroupedNotifications]
  let isGrouped: Bool
  let scope: NotificationScope
  let unreadOnly: Bool
  let selectedWorktreeID: Worktree.ID?
  let prunedCount: Int
  let hasNotificationsAnywhere: Bool
  let onClearFilters: () -> Void
  let onSelectNotification: (Worktree.ID, WorktreeTerminalNotification) -> Void
  let onMarkRead: (Worktree.ID, UUID) -> Void
  let onDismiss: (Worktree.ID, UUID) -> Void
  let onMarkAllRead: () -> Void
  let onDismissAll: () -> Void

  @State private var confirmingDismissAll = false

  var body: some View {
    let isEmpty = items.isEmpty && prunedCount == 0
    // `List` virtualizes rows (NSTableView), so a large backlog builds only the
    // on-screen rows on open, never the whole log or its markdown bodies.
    List {
      if isGrouped {
        ForEach(groupedItems) { group in
          Section {
            ForEach(group.items) { notification in
              NotificationRow(
                notification: notification,
                worktreeID: group.worktreeID,
                source: nil,
                onSelect: onSelectNotification,
                onMarkRead: onMarkRead,
                onDismiss: onDismiss
              )
            }
          } header: {
            NotificationGroupHeader(group: group)
          }
        }
      } else {
        ForEach(items) { item in
          NotificationRow(
            notification: item.notification,
            worktreeID: item.worktreeID,
            source: scope == .all ? Self.rowSource(item, selectedWorktreeID: selectedWorktreeID) : nil,
            onSelect: onSelectNotification,
            onMarkRead: onMarkRead,
            onDismiss: onDismiss
          )
        }
      }
      // One aggregate for evicted unread; timeless, so it sits at the bottom.
      if prunedCount > 0 {
        PrunedNotificationSummaryRow(count: prunedCount)
      }
    }
    .listStyle(.inset)
    // Let the window's terminal background (set in WindowChromeApplier) show through.
    .scrollContentBackground(.hidden)
    .scrollEdgeEffectStyle(.soft, for: .all)
    // The header bar sits only over the list, so it scrolls under it for the
    // native top blur; the empty state reserves no bar.
    .safeAreaBar(edge: .top) {
      if hasNotificationsAnywhere {
        NotificationsInspectorHeader(
          canAct: !isEmpty,
          onMarkAllRead: onMarkAllRead,
          onRequestDismissAll: { confirmingDismissAll = true }
        )
      }
    }
    // Overlay, not background, so the Show All button stays hittable above the list.
    .overlay {
      if isEmpty {
        NotificationsEmptyState(
          scope: scope,
          unreadOnly: unreadOnly,
          hasNotificationsElsewhere: hasNotificationsAnywhere,
          onClearFilters: onClearFilters
        )
      }
    }
    .confirmationDialog(
      // Dismiss All also clears pruned unread, so the count includes it.
      Self.dismissAllTitle(scope: scope, unreadOnly: unreadOnly, count: items.count + prunedCount),
      isPresented: $confirmingDismissAll,
      titleVisibility: .visible
    ) {
      Button("Dismiss All", role: .destructive, action: onDismissAll)
      Button("Cancel", role: .cancel) {}
    }
  }

  private static func dismissAllTitle(scope: NotificationScope, unreadOnly: Bool, count: Int) -> String {
    let suffix = scope == .currentWorktree ? " in this worktree" : ""
    let adjective = unreadOnly ? "unread " : ""
    guard count > 0 else { return "Dismiss all \(adjective)notifications\(suffix)?" }
    let noun = count == 1 ? "notification" : "notifications"
    return "Dismiss all \(count) \(adjective)\(noun)\(suffix)?"
  }

  private static func rowSource(
    _ item: FlatNotificationItem, selectedWorktreeID: Worktree.ID?
  ) -> NotificationRowSource {
    NotificationRowSource(
      repositoryName: item.repositoryName,
      repositoryColor: item.repositoryColor,
      worktreeName: item.worktreeName,
      isFolder: item.isFolder,
      isSelectedWorktree: item.worktreeID == selectedWorktreeID
    )
  }
}

private struct NotificationsInspectorHeader: View {
  let canAct: Bool
  let onMarkAllRead: () -> Void
  let onRequestDismissAll: () -> Void

  var body: some View {
    HStack {
      NotificationFilterMenu()
      Spacer()
      NotificationOverflowMenu(
        onMarkAllRead: onMarkAllRead,
        onRequestDismissAll: onRequestDismissAll
      )
      .disabled(!canAct)
    }
    .padding(.horizontal)
    .padding(.vertical)
  }
}

/// Scope filter (its label doubles as the pane title) plus the unread-only and
/// grouping toggles. Binds settings directly for stable bindings, not closures.
private struct NotificationFilterMenu: View {
  @Shared(.settingsFile) private var settingsFile

  var body: some View {
    let scope = settingsFile.global.notificationScope
    let unreadOnly = settingsFile.global.notificationsUnreadOnly
    Menu {
      Picker("Show Notifications From", selection: Binding($settingsFile.global.notificationScope)) {
        ForEach(NotificationScope.allCases, id: \.self) { option in
          Text(option.inspectorTitle).tag(option)
        }
      }
      .pickerStyle(.inline)
      .labelsHidden()
      Divider()
      Toggle("Unread Only", isOn: Binding($settingsFile.global.notificationsUnreadOnly))
      Toggle("Group into Worktrees", isOn: Binding($settingsFile.global.notificationsGroupedByWorktree))
    } label: {
      HStack(spacing: 3) {
        Text(scope.inspectorTitle)
          .appFont(.headline)
          .foregroundStyle(.primary)
        // Unread-only is easy to forget once set; flag it with the row dot.
        if unreadOnly {
          Circle()
            .fill(.orange)
            .frame(width: 6, height: 6)
            .padding(.trailing, 4)
            .accessibilityLabel("Unread only")
        }
        // A plain button menu draws no indicator, so supply the chevron here.
        Image(systemName: "chevron.down")
          .appFont(.caption2)
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
      }
    }
    // Plain button menu renders the label faithfully; borderless overrides its weight.
    .menuStyle(.button)
    .buttonStyle(.plain)
    .fixedSize()
    .help("Filter which worktrees' notifications are shown.")
  }
}

/// Section header for the grouped layout.
private struct NotificationGroupHeader: View {
  let group: GroupedNotifications

  var body: some View {
    NotificationSourceTag(
      repositoryName: group.repositoryName,
      repositoryColor: group.repositoryColor,
      worktreeName: group.worktreeName,
      isFolder: group.isFolder
    )
    .appFont(.subheadline, weight: .medium)
    .textCase(nil)
  }
}

/// Overflow menu; Dismiss All is destructive so the owner routes it through a
/// confirmation.
private struct NotificationOverflowMenu: View {
  let onMarkAllRead: () -> Void
  let onRequestDismissAll: () -> Void

  var body: some View {
    Menu {
      Button(action: onMarkAllRead) {
        Label("Mark All as Read", systemImage: "checkmark.circle")
      }
      Button(role: .destructive, action: onRequestDismissAll) {
        Label("Dismiss All", systemImage: "trash")
      }
    } label: {
      Image(systemName: "ellipsis")
        .appFont(.headline)
        .contentShape(.rect)
        .accessibilityLabel("More notification actions")
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("More notification actions.")
  }
}

/// Distinguishes "nothing anywhere" from "nothing matches the active filters",
/// which offers a one-tap reset back to every notification.
private struct NotificationsEmptyState: View {
  let scope: NotificationScope
  let unreadOnly: Bool
  let hasNotificationsElsewhere: Bool
  let onClearFilters: () -> Void

  var body: some View {
    if filtersActive, hasNotificationsElsewhere {
      ContentUnavailableView {
        Label(title, systemImage: "bell.slash")
      } description: {
        Text(message)
      } actions: {
        Button("Show All Notifications", action: onClearFilters)
      }
    } else {
      ContentUnavailableView(
        "No Notifications",
        systemImage: "bell.slash",
        description: Text("Agent and terminal notifications appear here.")
      )
    }
  }

  private var filtersActive: Bool {
    scope == .currentWorktree || unreadOnly
  }

  private var title: String {
    switch (unreadOnly, scope) {
    case (true, .currentWorktree): "No Unread in This Worktree"
    case (true, .all): "No Unread Notifications"
    case (false, _): "None in This Worktree"
    }
  }

  private var message: String {
    switch (unreadOnly, scope) {
    case (true, .currentWorktree): "Read notifications and other worktrees are hidden."
    case (true, .all): "Read notifications are hidden."
    case (false, _): "Notifications from other worktrees are hidden."
    }
  }
}

/// The repo/worktree source shown inside a flat-list row; nil in grouped mode
/// where the section header carries it instead.
private struct NotificationRowSource {
  let repositoryName: String
  let repositoryColor: RepositoryColor?
  let worktreeName: String
  let isFolder: Bool
  let isSelectedWorktree: Bool
}

private struct NotificationRow: View {
  let notification: WorktreeTerminalNotification
  let worktreeID: Worktree.ID
  let source: NotificationRowSource?
  let onSelect: (Worktree.ID, WorktreeTerminalNotification) -> Void
  let onMarkRead: (Worktree.ID, UUID) -> Void
  let onDismiss: (Worktree.ID, UUID) -> Void

  var body: some View {
    // Agent notifications carry the agent slug as the title; show its mark and name.
    let agent = SkillAgent(rawValue: notification.title.lowercased())
    let title = agent?.displayName ?? (notification.title.isEmpty ? "Terminal" : notification.title)
    // The whole row navigates to the source; the chevron is a passive affordance.
    Button {
      onSelect(worktreeID, notification)
    } label: {
      HStack(alignment: .top, spacing: 10) {
        NotificationSourceIcon(agent: agent)
          .padding(.top, 1)
        VStack(alignment: .leading, spacing: 3) {
          // Dimmed for other worktrees so the selected one stands out.
          if let source {
            NotificationSourceTag(
              repositoryName: source.repositoryName,
              repositoryColor: source.repositoryColor,
              worktreeName: source.worktreeName,
              isFolder: source.isFolder
            )
            .appFont(.caption)
            .opacity(source.isSelectedWorktree ? 1 : 0.5)
          }
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
              .appFont(.subheadline, weight: .semibold)
              .foregroundStyle(notification.isRead ? Color.secondary : Color.primary)
              .lineLimit(1)
            Spacer(minLength: 6)
            // Self-updating relative time, so the markdown body isn't re-parsed to tick.
            Text(notification.createdAt, style: .relative)
              .appFont(.caption)
              .foregroundStyle(.tertiary)
              .lineLimit(1)
              .fixedSize()
            // Unread indicator, matching the sidebar; reserves space when read so rows align.
            Circle()
              .fill(notification.isRead ? AnyShapeStyle(.clear) : AnyShapeStyle(.orange))
              .frame(width: 6, height: 6)
              .accessibilityHidden(true)
          }
          if !notification.body.isEmpty {
            NotificationBodyText(text: notification.body, isRead: notification.isRead)
          }
        }
        Image(systemName: "chevron.forward")
          .appFont(.caption)
          .foregroundStyle(.tertiary)
          .padding(.top, 1)
          .accessibilityHidden(true)
      }
      .padding(.vertical, 4)
      .contentShape(.rect)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .buttonStyle(.plain)
    .contextMenu {
      Button {
        Self.copyToPasteboard(title: title, body: notification.body)
      } label: {
        Label("Copy Notification", systemImage: "doc.on.doc")
      }
      Section {
        Button {
          onMarkRead(worktreeID, notification.id)
        } label: {
          Label("Mark as Read", systemImage: "checkmark.circle")
        }
        .disabled(notification.isRead)
        Button(role: .destructive) {
          onDismiss(worktreeID, notification.id)
        } label: {
          Label("Dismiss", systemImage: "trash")
        }
      }
    }
  }

  private static func copyToPasteboard(title: String, body: String) {
    var parts: [String] = []
    for part in [title, body] where !part.isEmpty {
      parts.append(part)
    }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(parts.joined(separator: "\n\n"), forType: .string)
  }
}

/// Colored repository name, then "· worktree" for non-folder repos. Shared by
/// the flat row source line and the grouped section header (which set the font).
private struct NotificationSourceTag: View {
  let repositoryName: String
  let repositoryColor: RepositoryColor?
  let worktreeName: String
  let isFolder: Bool

  var body: some View {
    HStack(spacing: 4) {
      // Repo keeps layout priority so the colored tag doesn't truncate first.
      Text(repositoryName)
        .foregroundStyle(repositoryStyle)
        .layoutPriority(1)
      // A folder's synthetic worktree repeats the repo name, so skip the trail.
      if !isFolder {
        Text(verbatim: "·")
          .foregroundStyle(.tertiary)
        Text(worktreeName)
          .foregroundStyle(.secondary)
      }
    }
    .lineLimit(1)
  }

  private var repositoryStyle: AnyShapeStyle {
    repositoryColor.map { AnyShapeStyle($0.color) } ?? AnyShapeStyle(.secondary)
  }
}

/// Notification body, capped at three lines. Truncated, not expandable: the row
/// click navigates to the source instead.
private struct NotificationBodyText: View {
  let text: String
  let isRead: Bool

  var body: some View {
    Text(Self.markdown(text))
      .appFont(.callout)
      .foregroundStyle(isRead ? Color.secondary : Color.primary)
      .lineLimit(3)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private static func markdown(_ string: String) -> AttributedString {
    (try? AttributedString(
      markdown: string,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    )) ?? AttributedString(string)
  }
}

/// Non-interactive aggregate reconciling the bell badge with the visible rows.
private struct PrunedNotificationSummaryRow: View {
  let count: Int

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      NotificationSourceIcon(agent: nil)
        .padding(.top, 1)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .appFont(.subheadline, weight: .semibold)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Text("Older unread cleared per your Notification settings.")
          .appFont(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(.vertical, 4)
    .contentShape(.rect)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var title: String {
    count == 1 ? "1 more unread beyond retention" : "\(count) more unread beyond retention"
  }
}

extension NotificationScope {
  fileprivate var inspectorTitle: String {
    switch self {
    case .all: "All Notifications"
    case .currentWorktree: "Current Worktree"
    }
  }
}

/// Leading source glyph: the agent's mark when the notification came from an
/// agent, otherwise a neutral bell in the same circular chrome so rows align.
private struct NotificationSourceIcon: View {
  let agent: SkillAgent?
  @Environment(\.pixelLength) private var pixelLength

  var body: some View {
    if let agent {
      AgentBadgeView(agent: agent, size: 22)
    } else {
      Image(systemName: "bell.fill")
        .appFont(.caption2)
        .foregroundStyle(.secondary)
        .frame(width: 22, height: 22)
        .background(.bar, in: .circle)
        .overlay(Circle().strokeBorder(.separator, lineWidth: pixelLength))
        .accessibilityHidden(true)
    }
  }
}
