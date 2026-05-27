import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

/// Layout constants shared by the leaf row (`SidebarItemView`) and the group
/// header row so indentation stays in lock-step across both view files.
enum SidebarNestLayout {
  /// Pixel step a row indents per branch-nesting depth level.
  static let indentStep: CGFloat = 14
}

/// Repo identity carried alongside a sidebar row so the highlight sections
/// can render a colored `repo · worktree` subtitle that mirrors the window
/// toolbar. `nil` on a row keeps the standard per-repo subtitle.
struct SidebarHighlightRepoTag: Equatable, Hashable, Sendable {
  let repoName: String
  let repoColor: RepositoryColor?
}

struct SidebarItemView: View {
  let store: StoreOf<SidebarItemFeature>
  let hideSubtitle: Bool
  let hideSubtitleOnMatch: Bool
  let showsPullRequestInfo: Bool
  let shortcutHint: String?
  /// Trailing branch-component label injected by the branch-nesting renderer so
  /// a row nested under a `feature/tools` header reads as `a` instead of the
  /// full `feature/tools/a`. `nil` keeps the original branch name.
  var displayNameOverride: String?
  /// Number of group-header ancestors above this row, used by the renderer
  /// to apply a per-level leading indent. `0` keeps the existing baseline.
  var nestDepth: Int = 0
  /// Non-nil only inside the global Pinned / Active sections.
  var highlightSubtitle: SidebarHighlightRepoTag?

  var body: some View {
    let resolved = ResolvedRowDisplay(
      kind: store.kind,
      branchName: displayNameOverride ?? store.branchName,
      worktreeName: store.sidebarDisplayName,
      isMainWorktree: store.isMainWorktree,
      isPinned: store.isPinned,
      hideSubtitle: hideSubtitle,
      hideSubtitleOnMatch: hideSubtitleOnMatch,
      highlightSubtitle: highlightSubtitle,
      customTitle: store.customTitle,
      customTint: store.customTint
    )

    Label {
      HStack(spacing: 8) {
        TitleView(
          name: resolved.name,
          subtitle: resolved.subtitle,
          accent: resolved.accent,
          customTint: store.customTint,
          isLifecycleBusy: store.lifecycle.isBusy,
          isTaskRunning: store.isTaskRunning
        )
        .equatable()
        Spacer(minLength: 0)
        TrailingView(
          store: store,
          shortcutHint: shortcutHint,
          showsPullRequestInfo: showsPullRequestInfo
        )
      }
    } icon: {
      IconView(
        isFolder: store.kind == .folder,
        isMissing: store.isMissing,
        branchName: store.branchName,
        pullRequest: store.pullRequest,
        showsPullRequestInfo: showsPullRequestInfo,
        lifecycle: store.lifecycle
      )
    }
    .labelStyle(.verticallyCentered)
    .listRowInsets(.leading, CGFloat(nestDepth) * SidebarNestLayout.indentStep)
    .listRowInsets(.trailing, 4)
    .listRowInsets(.vertical, 6)
  }
}

struct ResolvedRowDisplay: Equatable {
  enum Subtitle: Equatable {
    case none
    /// Standard per-repo subtitle. Rendered in the row's accent color.
    case plain(String)
    /// Highlight-section subtitle: `repo · trail`. `repo` paints with
    /// `repoColor`, `trail` with the row's accent. `trail == nil` collapses
    /// to just the repo name.
    case highlight(repo: String, repoColor: RepositoryColor?, trail: String?)
  }

  let name: String
  let subtitle: Subtitle
  let accent: WorktreeAccent

  init(
    kind: SidebarItemFeature.State.Kind,
    branchName: String,
    worktreeName: String?,
    isMainWorktree: Bool,
    isPinned: Bool,
    hideSubtitle: Bool,
    hideSubtitleOnMatch: Bool,
    highlightSubtitle: SidebarHighlightRepoTag? = nil,
    customTitle: String? = nil,
    customTint: RepositoryColor? = nil
  ) {
    self.accent =
      if isMainWorktree { .main } else if isPinned { .pinned } else { .default }

    // User override (trimmed) takes precedence over derived names.
    let resolvedCustom = SidebarDisplayName.resolved(custom: customTitle, fallback: nil)
    let hasCustomTitle = resolvedCustom != nil

    if kind == .folder {
      self.name = resolvedCustom ?? branchName
      // Folder rows ARE the repo, so a repo prefix would just repeat the title.
      self.subtitle = .none
      return
    }

    let resolvedWorktreeName = worktreeName ?? "Default"
    let effectiveWorktreeName = resolvedWorktreeName.isEmpty ? branchName : resolvedWorktreeName
    self.name = resolvedCustom ?? branchName

    let branchLastComponent = branchName.split(separator: "/").last.map(String.init) ?? branchName
    let isMatch = effectiveWorktreeName == branchLastComponent
    // Once a user types a custom title, they've lost the visual cue that the auto-derived name was
    // providing, so we always render the subtitle even when it would otherwise collapse on match.
    let shouldHideOnMatch = hideSubtitleOnMatch && !hasCustomTitle && isMatch

    if let highlightSubtitle {
      let trail: String?
      if shouldHideOnMatch {
        trail = nil
      } else if isMainWorktree {
        trail = "Default"
      } else if let worktreeName, !worktreeName.isEmpty {
        trail = worktreeName
      } else {
        trail = nil
      }
      self.subtitle = .highlight(
        repo: highlightSubtitle.repoName,
        repoColor: highlightSubtitle.repoColor,
        trail: trail
      )
      return
    }

    if hideSubtitle || shouldHideOnMatch {
      self.subtitle = .none
    } else {
      self.subtitle = .plain(effectiveWorktreeName)
    }
  }
}

enum SidebarCheckBadgeState: Equatable {
  case passing
  case failing
  case inProgress

  var symbolName: String {
    switch self {
    case .passing: "checkmark"
    case .failing: "xmark"
    case .inProgress: "ellipsis"
    }
  }

  var color: Color {
    switch self {
    case .passing: .green
    case .failing: .red
    case .inProgress: .yellow
    }
  }

  var accessibilityLabel: String {
    switch self {
    case .passing: "Checks passed"
    case .failing: "Checks failed"
    case .inProgress: "Checks in progress"
    }
  }
}

enum SidebarPullRequestIcon: Equatable {
  case branch
  case open
  case draft
  case queued
  case merged
  case closed

  static func resolve(_ pullRequest: GithubPullRequest?) -> Self {
    guard let pullRequest else { return .branch }
    switch pullRequest.state.uppercased() {
    case "MERGED": return .merged
    case "CLOSED": return .closed
    case "OPEN" where pullRequest.isDraft: return .draft
    case "OPEN" where PullRequestMergeQueueStatus(pullRequest: pullRequest) != nil: return .queued
    case "OPEN": return .open
    default: return .branch
    }
  }

  var assetName: String {
    switch self {
    case .branch: "git-branch"
    case .open: "git-pull-request"
    case .draft: "git-pull-request-draft"
    case .queued: "git-merge-queue"
    case .merged: "git-merge"
    case .closed: "git-pull-request-closed"
    }
  }

  var color: AnyShapeStyle {
    switch self {
    case .branch: AnyShapeStyle(.secondary)
    case .open: AnyShapeStyle(.green)
    case .draft: AnyShapeStyle(.tertiary)
    case .queued: AnyShapeStyle(.brown)
    case .merged: AnyShapeStyle(.purple)
    case .closed: AnyShapeStyle(.red)
    }
  }
}

private func resolveCheckBadgeState(_ pullRequest: GithubPullRequest?) -> SidebarCheckBadgeState? {
  guard let checks = pullRequest?.statusCheckRollup?.checks, !checks.isEmpty else { return nil }
  let breakdown = PullRequestCheckBreakdown(checks: checks)
  if breakdown.failed > 0 { return .failing }
  if breakdown.inProgress > 0 || breakdown.expected > 0 { return .inProgress }
  return .passing
}

private struct TitleView: View, Equatable {
  let name: String
  let subtitle: ResolvedRowDisplay.Subtitle
  let accent: WorktreeAccent
  /// User-supplied row tint. When set, paints the title; otherwise the title uses the default.
  let customTint: RepositoryColor?
  let isLifecycleBusy: Bool
  let isTaskRunning: Bool
  // `==` ignores @Environment; SwiftUI tracks env changes separately.
  @Environment(\.backgroundProminence) private var backgroundProminence

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.name == rhs.name
      && lhs.subtitle == rhs.subtitle
      && lhs.accent == rhs.accent
      && lhs.customTint == rhs.customTint
      && lhs.isLifecycleBusy == rhs.isLifecycleBusy
      && lhs.isTaskRunning == rhs.isTaskRunning
  }

  var body: some View {
    let isBusy = isLifecycleBusy || isTaskRunning
    let isEmphasized = backgroundProminence == .increased
    let accentStyle = accent.shapeStyle(emphasized: isEmphasized)
    VStack(alignment: .leading, spacing: 0) {
      let titleText = Text(name)
        .font(.body)
        .lineLimit(1)
      if let customTint, !isEmphasized {
        titleText.foregroundStyle(customTint.color).shimmer(isActive: isBusy)
      } else {
        titleText.shimmer(isActive: isBusy)
      }
      switch subtitle {
      case .none:
        EmptyView()
      case .plain(let text):
        Text(text)
          .font(.footnote)
          .foregroundStyle(accentStyle)
          .lineLimit(1)
      case .highlight(let repo, let repoColor, let trail):
        let repoStyle: AnyShapeStyle =
          isEmphasized
          ? AnyShapeStyle(.secondary)
          : repoColor.map { AnyShapeStyle($0.color) } ?? AnyShapeStyle(.secondary)
        // `.layoutPriority(1)` on the repo makes the trail yield first under a narrow sidebar.
        HStack(spacing: 0) {
          Text(repo)
            .foregroundStyle(repoStyle)
            .lineLimit(1)
            .layoutPriority(1)
          if let trail {
            Text(" · ")
              .foregroundStyle(.secondary)
              .lineLimit(1)
            Text(trail)
              .foregroundStyle(accentStyle)
              .lineLimit(1)
          }
        }
        .font(.footnote)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(trail.map { "\(repo), \($0)" } ?? repo)
      }
    }
  }
}

private struct IconView: View {
  let isFolder: Bool
  let isMissing: Bool
  let branchName: String
  let pullRequest: GithubPullRequest?
  let showsPullRequestInfo: Bool
  let lifecycle: SidebarItemFeature.State.Lifecycle

  var body: some View {
    let display = WorktreePullRequestDisplay(
      worktreeName: branchName,
      pullRequest: showsPullRequestInfo ? pullRequest : nil,
    )
    IconContent(
      isFolder: isFolder,
      isMissing: isMissing,
      icon: SidebarPullRequestIcon.resolve(display.pullRequest),
      checkBadgeState: resolveCheckBadgeState(display.pullRequest),
      rowState: IconRowState(lifecycle),
    )
    .equatable()
  }
}

enum IconRowState: Equatable {
  case idle
  case pending
  case archiving
  case deleting

  init(_ lifecycle: SidebarItemFeature.State.Lifecycle) {
    switch lifecycle {
    case .idle: self = .idle
    case .pending: self = .pending
    case .archiving: self = .archiving
    case .deleting, .deletingScript: self = .deleting
    }
  }
}

private struct IconContent: View, Equatable {
  let isFolder: Bool
  let isMissing: Bool
  let icon: SidebarPullRequestIcon
  let checkBadgeState: SidebarCheckBadgeState?
  let rowState: IconRowState
  // `==` ignores @Environment; SwiftUI tracks env changes separately.
  @Environment(\.backgroundProminence) private var backgroundProminence

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.isFolder == rhs.isFolder
      && lhs.isMissing == rhs.isMissing
      && lhs.icon == rhs.icon
      && lhs.checkBadgeState == rhs.checkBadgeState
      && lhs.rowState == rhs.rowState
  }

  private var isEmphasized: Bool {
    backgroundProminence == .increased
  }

  private var isSystemImage: Bool {
    rowState != .idle || isFolder || isMissing
  }

  private var folderIconName: String {
    if isMissing { return "exclamationmark.triangle.fill" }
    switch rowState {
    case .pending: return "truck.box.badge.clock"
    case .archiving: return "archivebox"
    case .deleting: return "trash"
    case .idle: return "folder"
    }
  }

  private var folderColor: AnyShapeStyle {
    guard !isEmphasized else { return AnyShapeStyle(.secondary) }
    if isMissing { return AnyShapeStyle(.orange) }
    switch rowState {
    case .pending: return AnyShapeStyle(.blue)
    case .archiving: return AnyShapeStyle(.orange)
    case .deleting: return AnyShapeStyle(.red)
    case .idle: return AnyShapeStyle(.secondary)
    }
  }

  private var accessibilityLabel: String? {
    if isMissing { return "Working directory missing" }
    switch rowState {
    case .pending: return "Creating"
    case .archiving: return "Archiving"
    case .deleting: return "Deleting"
    case .idle: return nil
    }
  }

  var body: some View {
    Group {
      if isSystemImage {
        Image(systemName: folderIconName)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .fontWeight(.semibold)
          .foregroundStyle(folderColor)
      } else {
        Image(icon.assetName)
          .renderingMode(.template)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .foregroundStyle(isEmphasized ? AnyShapeStyle(.secondary) : icon.color)
      }
    }
    .frame(width: 16, height: 16)
    .overlay(alignment: .bottomTrailing) {
      if let checkBadgeState, !isSystemImage {
        let badgeColor = AnyShapeStyle(checkBadgeState.color)
        let background = AnyShapeStyle(.windowBackground)
        Image(systemName: checkBadgeState.symbolName)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .symbolVariant(.circle.fill)
          .symbolRenderingMode(.palette)
          .fontWeight(.black)
          .frame(width: 10, height: 10)
          .foregroundStyle(
            isEmphasized ? badgeColor : background,
            isEmphasized ? background : badgeColor,
          )
          .background(in: Circle())
          .accessibilityLabel(checkBadgeState.accessibilityLabel)
          .offset(x: 2, y: 2)
      }
    }
    .accessibilityLabel(accessibilityLabel ?? "")
    .accessibilityHidden(accessibilityLabel == nil)
  }
}

private struct TrailingView: View {
  let store: StoreOf<SidebarItemFeature>
  let shortcutHint: String?
  let showsPullRequestInfo: Bool

  var body: some View {
    if let shortcutHint {
      Text(shortcutHint)
        .font(.caption)
        .foregroundStyle(.secondary)
    } else {
      let display = WorktreePullRequestDisplay(
        worktreeName: store.branchName,
        pullRequest: showsPullRequestInfo ? store.pullRequest : nil,
      )
      let prText = display.pullRequestBadgeStyle?.text
      let agents = store.agents
      let scriptColors = store.runningScripts.map(\.tint)
      let showsNotificationIndicator = store.hasUnseenNotifications
      let notifications = Array(store.notifications)
      let added = store.addedLines ?? 0
      let removed = store.removedLines ?? 0
      let hasStats = added + removed > 0
      let hasStatus = !scriptColors.isEmpty || showsNotificationIndicator

      HStack(spacing: 6) {
        if hasStats {
          DiffStatsContent(addedLines: added, removedLines: removed)
            .equatable()
        }
        if let prText {
          PullRequestBadgeContent(text: prText)
            .equatable()
        }
        if !agents.isEmpty {
          RunningAgentsBadgeContent(agents: agents)
            .equatable()
        }
        if hasStatus {
          StatusIndicator(
            runningScriptColors: scriptColors,
            showsNotificationIndicator: showsNotificationIndicator,
            notifications: notifications,
          )
          .equatable()
        }
      }
      // Title takes the squeeze under narrow widths, not the counters.
      .fixedSize(horizontal: true, vertical: false)
    }
  }
}

private struct PullRequestBadgeContent: View, Equatable {
  let text: String

  var body: some View {
    Text(text)
      .font(.caption)
      .foregroundStyle(.secondary)
      .transition(.blurReplace)
  }
}

private struct RunningAgentsBadgeContent: View, Equatable {
  let agents: [AgentPresenceFeature.AgentInstance]

  var body: some View {
    AgentAvatarGroupView(instances: agents, size: 16)
  }
}

private struct DiffStatsContent: View, Equatable {
  let addedLines: Int
  let removedLines: Int
  // `==` ignores @Environment; SwiftUI tracks env changes separately.
  @Environment(\.backgroundProminence) private var backgroundProminence

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.addedLines == rhs.addedLines && lhs.removedLines == rhs.removedLines
  }

  var body: some View {
    let isEmphasized = backgroundProminence == .increased
    HStack(spacing: 2) {
      Text("+\(addedLines)")
        .foregroundStyle(isEmphasized ? AnyShapeStyle(.secondary) : AnyShapeStyle(.green))
      Text("-\(removedLines)")
        .foregroundStyle(isEmphasized ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
    }
    .font(.caption)
    .monospacedDigit()
    .transition(.blurReplace)
  }
}

private struct StatusIndicator: View, Equatable {
  let runningScriptColors: [RepositoryColor]
  let showsNotificationIndicator: Bool
  let notifications: [WorktreeTerminalNotification]
  // `==` ignores @Environment; SwiftUI tracks env changes separately.
  @Environment(\.backgroundProminence) private var backgroundProminence
  @Environment(\.focusNotificationAction) private var focusNotificationAction: (WorktreeTerminalNotification) -> Void

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.runningScriptColors == rhs.runningScriptColors
      && lhs.showsNotificationIndicator == rhs.showsNotificationIndicator
      && lhs.notifications == rhs.notifications
  }

  var body: some View {
    let isEmphasized = backgroundProminence == .increased
    let isRunning = !runningScriptColors.isEmpty
    if isRunning || showsNotificationIndicator {
      ZStack {
        if isRunning {
          SidebarPingMultiColorDot(
            colors: runningScriptColors,
            isEmphasized: isEmphasized,
            size: 6,
            showsSolidCenter: !showsNotificationIndicator
          )
        }
        if showsNotificationIndicator {
          NotificationPopoverButton(notifications: notifications) {
            Circle()
              .fill(.orange)
              .frame(width: 6, height: 6)
              .accessibilityLabel("Unread notifications")
          }
          .zIndex(1)
        }
      }
      .transition(.blurReplace)
    }
  }
}

private nonisolated let notificationEnvironmentLogger = SupaLogger("Notifications")

extension EnvironmentValues {
  @Entry var focusNotificationAction: (WorktreeTerminalNotification) -> Void = { _ in
    notificationEnvironmentLogger.warning("focusNotificationAction called but was never set in the environment.")
  }
}
