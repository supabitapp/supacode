import AppKit
import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

/// Single inspector column whose content switches on the active pane.
struct WorktreeStatusInspectorContainer: View {
  let pane: WorktreeInspectorPane
  let isFolder: Bool
  let isCheckingPullRequest: Bool
  let pullRequest: GithubPullRequest?
  let repositoriesStore: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager
  let onSelectNotification: (Worktree.ID, WorktreeTerminalNotification) -> Void
  let onSelectSurface: (Worktree.ID, UUID) -> Void
  let onPullRequestAction: (RepositoriesFeature.PullRequestAction) -> Void

  var body: some View {
    Group {
      switch pane {
      case .git:
        WorktreeGitInspectorView(
          pullRequest: pullRequest,
          isFolder: isFolder,
          isCheckingPullRequest: isCheckingPullRequest,
          onPullRequestAction: onPullRequestAction
        )
      case .notifications:
        WorktreeNotificationsInspectorView(
          repositoriesStore: repositoriesStore,
          terminalManager: terminalManager,
          onSelectNotification: onSelectNotification,
          onSelectSurface: onSelectSurface
        )
      }
    }
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
  let pullRequest: GithubPullRequest?
  let isFolder: Bool
  let isCheckingPullRequest: Bool
  let onPullRequestAction: (RepositoriesFeature.PullRequestAction) -> Void

  var body: some View {
    if isFolder {
      ContentUnavailableView(
        "Not a Git Repository",
        systemImage: "folder",
        description: Text("This folder isn't a git repository.")
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if let pullRequest {
      GitInspectorContent(pullRequest: pullRequest, onPullRequestAction: onPullRequestAction)
    } else if isCheckingPullRequest {
      VStack(spacing: 10) {
        ProgressView()
        Text("Checking for pull request…")
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ContentUnavailableView(
        "No Pull Request",
        systemImage: "arrow.trianglehead.branch",
        description: Text("This worktree has no open pull request.")
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

private struct GitInspectorContent: View {
  let pullRequest: GithubPullRequest
  let onPullRequestAction: (RepositoriesFeature.PullRequestAction) -> Void
  @Environment(\.openURL) private var openURL
  @Environment(\.analyticsClient) private var analyticsClient

  var body: some View {
    let url = URL(string: pullRequest.url)
    let checks = pullRequest.statusCheckRollup?.checks ?? []
    let breakdown = PullRequestCheckBreakdown(checks: checks)
    let sortedChecks = Self.sortedChecks(checks)
    let readiness = PullRequestMergeReadiness(pullRequest: pullRequest)
    let mergeQueueStatus = PullRequestMergeQueueStatus(pullRequest: pullRequest)
    let badge = PullRequestBadgeStyle.style(
      state: pullRequest.state,
      number: pullRequest.number,
      isQueued: mergeQueueStatus != nil
    )

    VStack(spacing: 0) {
      HStack {
        Text("Pull Request")
          .font(.headline)
        Spacer()
        if let url {
          Button("Open on GitHub", systemImage: "arrow.up.right.square") {
            analyticsClient.capture("github_pr_opened", nil)
            openURL(url)
          }
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .help("Open pull request on GitHub.")
        }
      }
      .padding(.horizontal)
      .padding(.vertical, 10)
      Divider()

      Form {
        Section {
          LabeledContent("Author", value: pullRequest.authorLogin ?? "Someone")
          LabeledContent("Commits", value: (pullRequest.commitsCount ?? 0).formatted())
          LabeledContent("Changes") {
            HStack(spacing: 6) {
              Text("+\(pullRequest.additions.formatted())").foregroundStyle(.green)
              Text("-\(pullRequest.deletions.formatted())").foregroundStyle(.red)
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
            HStack {
              if let badge {
                PullRequestBadgeView(
                  text: pullRequest.isDraft ? "DRAFT" : badge.text,
                  color: badge.color)
              }
              Spacer()
              Text(verbatim: "#\(pullRequest.number)")
                .foregroundStyle(.secondary)
            }
            Text(pullRequest.title)
              .font(.headline)
              .textSelection(.enabled)
            Text(
              "`\(pullRequest.baseRefName ?? "base")` ← `\(pullRequest.headRefName ?? "branch")`"
            )
            .font(.subheadline)
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
          onPullRequestAction: onPullRequestAction
        )

        if breakdown.total > 0 {
          Section("Checks") {
            HStack(spacing: 8) {
              PullRequestChecksRingView(breakdown: breakdown)
              Text(breakdown.summaryText)
                .foregroundStyle(.secondary)
                .font(.callout)
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
    }
  }

  private static func sortedChecks(_ checks: [GithubPullRequestStatusCheck])
    -> [GithubPullRequestStatusCheck]
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

  private static func sortRank(for state: GithubPullRequestCheckState) -> Int {
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
  let pullRequest: GithubPullRequest
  let breakdown: PullRequestCheckBreakdown
  let onPullRequestAction: (RepositoriesFeature.PullRequestAction) -> Void

  var body: some View {
    let isOpen = pullRequest.state.uppercased() == "OPEN"
    let isDraft = pullRequest.isDraft
    let canMerge = isOpen && !isDraft && !PullRequestMergeReadiness(pullRequest: pullRequest).isBlocking
    let hasFailingChecks = breakdown.failed > 0
    let checks = pullRequest.statusCheckRollup?.checks ?? []
    let hasFailingCheckWithDetails = checks.contains { $0.checkState == .failure && $0.detailsUrl != nil }

    if isOpen {
      Section("Actions") {
        if canMerge {
          PullRequestActionRow(title: "Merge Pull Request", icon: .asset(SidebarPullRequestIcon.merged.assetName)) {
            onPullRequestAction(.merge)
          }
        }
        if isDraft {
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
          PullRequestActionRow(title: "Copy CI Failure Logs", icon: .symbol("doc.on.clipboard")) {
            onPullRequestAction(.copyCiFailureLogs)
          }
          PullRequestActionRow(title: "Re-run Failed Jobs", icon: .symbol("arrow.clockwise")) {
            onPullRequestAction(.rerunFailedJobs)
          }
          if hasFailingCheckWithDetails {
            PullRequestActionRow(title: "Open Failing Check Details", icon: .symbol("arrow.up.right.square")) {
              onPullRequestAction(.openFailingCheckDetails)
            }
          }
        }
        PullRequestActionRow(
          title: "Close Pull Request",
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
  let check: GithubPullRequestStatusCheck
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
  let check: GithubPullRequestStatusCheck
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
        .font(.caption)
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
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Notifications pane

/// Inspector pane for worktree notifications. Reads the notification cache in
/// its own body so notification churn invalidates only this pane, mirroring the
/// toolbar bell host.
struct WorktreeNotificationsInspectorView: View {
  let repositoriesStore: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager
  let onSelectNotification: (Worktree.ID, WorktreeTerminalNotification) -> Void
  let onSelectSurface: (Worktree.ID, UUID) -> Void

  var body: some View {
    let groups = repositoriesStore.toolbarNotificationGroupsCache
    NotificationsInspectorContent(
      groups: groups,
      onSelectNotification: onSelectNotification,
      onSelectSurface: onSelectSurface,
      onDismissAll: {
        for repositoryGroup in groups {
          for worktreeGroup in repositoryGroup.worktrees {
            terminalManager.stateIfExists(for: worktreeGroup.id)?
              .dismissAllNotifications()
          }
        }
      }
    )
  }
}

private struct NotificationsInspectorContent: View {
  let groups: [ToolbarNotificationRepositoryGroup]
  let onSelectNotification: (Worktree.ID, WorktreeTerminalNotification) -> Void
  let onSelectSurface: (Worktree.ID, UUID) -> Void
  let onDismissAll: () -> Void

  var body: some View {
    let count = groups.reduce(0) { $0 + $1.notificationCount }
    let unseenCount = groups.flatMap(\.worktrees).reduce(0) { $0 + $1.unseenNotificationCount }
    VStack(spacing: 0) {
      HStack {
        Text("Notifications")
          .font(.headline)
        Spacer()
        Button("Dismiss All", action: onDismissAll)
          .buttonStyle(.borderless)
          .disabled(count == 0 && unseenCount == 0)
          .help("Dismiss all notifications.")
      }
      .padding(.horizontal)
      .padding(.vertical, 10)
      Divider()

      if groups.isEmpty {
        ContentUnavailableView(
          "No Notifications",
          systemImage: "bell.slash",
          description: Text("Agent and terminal notifications appear here.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        // `List` virtualizes rows (NSTableView), so a large backlog builds only
        // the on-screen rows on open, never the whole log or its markdown bodies.
        List {
          ForEach(groups) { repository in
            ForEach(repository.worktrees) { worktree in
              Section {
                ForEach(worktree.notifications) { notification in
                  NotificationRow(
                    notification: notification,
                    worktreeID: worktree.id,
                    onSelect: onSelectNotification
                  )
                }
                // Unread whose notifications the cap pruned still needs a way
                // back to the surface, so synthesize a row per orphaned surface.
                ForEach(worktree.prunedUnseenSurfaces) { surface in
                  PrunedNotificationRow(
                    surface: surface,
                    worktreeID: worktree.id,
                    onSelect: onSelectSurface
                  )
                }
              } header: {
                NotificationWorktreeHeader(repository: repository, worktree: worktree)
              }
            }
          }
        }
        .listStyle(.inset)
        // Let the window's terminal background (set in WindowChromeApplier) show through.
        .scrollContentBackground(.hidden)
      }
    }
  }
}

/// Section header mirroring the sidebar's row identity: colored repo name,
/// folder glyph for folder repos, and the worktree's sidebar title.
private struct NotificationWorktreeHeader: View {
  let repository: ToolbarNotificationRepositoryGroup
  let worktree: ToolbarNotificationWorktreeGroup

  var body: some View {
    HStack(spacing: 5) {
      if repository.isFolder {
        Image(systemName: "folder")
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 14, height: 14)
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
      } else {
        Image(worktree.pullRequestIcon.assetName)
          .renderingMode(.template)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 14, height: 14)
          .foregroundStyle(worktree.pullRequestIcon.color)
          .help(worktree.pullRequestIcon.statusDescription)
          .accessibilityLabel(worktree.pullRequestIcon.statusDescription)
      }
      // Repo keeps layout priority so the colored tag doesn't truncate first,
      // mirroring the sidebar highlight subtitle.
      Text(repository.name)
        .foregroundStyle(repositoryStyle)
        .layoutPriority(1)
      // A folder's synthetic worktree repeats the repo name; skip the trail.
      if !repository.isFolder {
        Text(verbatim: "·")
          .foregroundStyle(.tertiary)
        Text(worktree.name)
          .foregroundStyle(.secondary)
      }
    }
    .font(.subheadline.weight(.medium))
    .lineLimit(1)
    .textCase(nil)
  }

  private var repositoryStyle: AnyShapeStyle {
    repository.color.map { AnyShapeStyle($0.color) } ?? AnyShapeStyle(.secondary)
  }
}

private struct NotificationRow: View {
  let notification: WorktreeTerminalNotification
  let worktreeID: Worktree.ID
  let onSelect: (Worktree.ID, WorktreeTerminalNotification) -> Void

  var body: some View {
    // Notification titles are the agent slug ("claude", "codex", …) when the
    // notification came from an agent; show its mark and display name instead.
    let agent = SkillAgent(rawValue: notification.title.lowercased())
    let title = agent?.displayName ?? (notification.title.isEmpty ? "Terminal" : notification.title)
    Button {
      onSelect(worktreeID, notification)
    } label: {
      HStack(alignment: .top, spacing: 10) {
        NotificationSourceIcon(agent: agent)
          .padding(.top, 1)
        VStack(alignment: .leading, spacing: 2) {
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(notification.isRead ? Color.secondary : Color.primary)
              .lineLimit(1)
            Spacer(minLength: 6)
            // Self-updating relative time; no shared clock needed, so a row's
            // markdown body is never re-parsed just to advance the timestamp.
            Text(notification.createdAt, style: .relative)
              .font(.caption)
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
            Text(Self.markdown(notification.body))
              .font(.callout)
              .foregroundStyle(notification.isRead ? Color.secondary : Color.primary)
              .fixedSize(horizontal: false, vertical: true)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
      .padding(.vertical, 4)
      .contentShape(.rect)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .buttonStyle(.plain)
    .help("Select worktree and focus terminal.")
  }

  private static func markdown(_ string: String) -> AttributedString {
    (try? AttributedString(
      markdown: string,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    )) ?? AttributedString(string)
  }
}

/// Synthesized row for a surface whose unread notifications the cap already
/// pruned from the log. Keeps the unread reachable: tapping focuses the surface.
private struct PrunedNotificationRow: View {
  let surface: WorktreeUnseenSurface
  let worktreeID: Worktree.ID
  let onSelect: (Worktree.ID, UUID) -> Void

  var body: some View {
    Button {
      onSelect(worktreeID, surface.id)
    } label: {
      HStack(alignment: .top, spacing: 10) {
        NotificationSourceIcon(agent: nil)
          .padding(.top, 1)
        VStack(alignment: .leading, spacing: 2) {
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(.primary)
              .lineLimit(1)
            Spacer(minLength: 6)
            Circle()
              .fill(.orange)
              .frame(width: 6, height: 6)
              .accessibilityHidden(true)
          }
          Text("Cleared per your Notification settings.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(.vertical, 4)
      .contentShape(.rect)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .buttonStyle(.plain)
    .help("Select worktree and focus terminal.")
  }

  private var title: String {
    surface.count == 1 ? "1 unread notification" : "\(surface.count) unread notifications"
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
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(width: 22, height: 22)
        .background(.bar, in: .circle)
        .overlay(Circle().strokeBorder(.separator, lineWidth: pixelLength))
        .accessibilityHidden(true)
    }
  }
}
