import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

struct SidebarItemView: View {
  let store: StoreOf<SidebarItemFeature>
  let displayMode: WorktreeRowDisplayMode
  let hideSubtitle: Bool
  let hideSubtitleOnMatch: Bool
  let showsPullRequestInfo: Bool
  let shortcutHint: String?

  var body: some View {
    let resolved = ResolvedRowDisplay(
      kind: store.kind,
      branchName: store.branchName,
      worktreeName: store.sidebarDisplayName,
      isMainWorktree: store.isMainWorktree,
      isPinned: store.isPinned,
      displayMode: displayMode,
      hideSubtitle: hideSubtitle,
      hideSubtitleOnMatch: hideSubtitleOnMatch
    )

    Label {
      HStack(spacing: 8) {
        TitleView(
          name: resolved.name,
          subtitle: resolved.subtitle,
          accent: resolved.accent,
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
        branchName: store.branchName,
        pullRequest: store.pullRequest,
        showsPullRequestInfo: showsPullRequestInfo,
        lifecycle: store.lifecycle
      )
    }
    .labelStyle(.verticallyCentered)
    .listRowInsets(.trailing, 4)
    .listRowInsets(.vertical, 6)
  }
}

struct ResolvedRowDisplay: Equatable {
  let name: String
  let subtitle: String?
  let accent: WorktreeAccent

  init(
    kind: SidebarItemFeature.State.Kind,
    branchName: String,
    worktreeName: String?,
    isMainWorktree: Bool,
    isPinned: Bool,
    displayMode: WorktreeRowDisplayMode,
    hideSubtitle: Bool,
    hideSubtitleOnMatch: Bool
  ) {
    self.accent =
      if isMainWorktree { .main } else if isPinned { .pinned } else { .default }

    if kind == .folder {
      self.name = branchName
      self.subtitle = nil
      return
    }

    let resolvedWorktreeName = worktreeName ?? "Default"
    let effectiveWorktreeName = resolvedWorktreeName.isEmpty ? branchName : resolvedWorktreeName
    switch displayMode {
    case .branchFirst: self.name = branchName
    case .worktreeFirst: self.name = effectiveWorktreeName
    }

    let branchLastComponent = branchName.split(separator: "/").last.map(String.init) ?? branchName
    let isMatch = effectiveWorktreeName == branchLastComponent
    let rawSubtitle = displayMode == .branchFirst ? effectiveWorktreeName : branchName
    if hideSubtitle || (hideSubtitleOnMatch && isMatch) {
      self.subtitle = nil
    } else {
      self.subtitle = rawSubtitle
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
  case merged
  case closed

  static func resolve(_ pullRequest: GithubPullRequest?) -> Self {
    guard let pullRequest else { return .branch }
    switch pullRequest.state.uppercased() {
    case "MERGED": return .merged
    case "CLOSED": return .closed
    case "OPEN" where pullRequest.isDraft: return .draft
    case "OPEN": return .open
    default: return .branch
    }
  }

  var assetName: String {
    switch self {
    case .branch: "git-branch"
    case .open: "git-pull-request"
    case .draft: "git-pull-request-draft"
    case .merged: "git-merge"
    case .closed: "git-pull-request-closed"
    }
  }

  var color: AnyShapeStyle {
    switch self {
    case .branch: AnyShapeStyle(.secondary)
    case .open: AnyShapeStyle(.green)
    case .draft: AnyShapeStyle(.tertiary)
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
  let subtitle: String?
  let accent: WorktreeAccent
  let isLifecycleBusy: Bool
  let isTaskRunning: Bool
  // `==` ignores @Environment; SwiftUI tracks env changes separately.
  @Environment(\.backgroundProminence) private var backgroundProminence

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.name == rhs.name
      && lhs.subtitle == rhs.subtitle
      && lhs.accent == rhs.accent
      && lhs.isLifecycleBusy == rhs.isLifecycleBusy
      && lhs.isTaskRunning == rhs.isTaskRunning
  }

  var body: some View {
    let isBusy = isLifecycleBusy || isTaskRunning
    VStack(alignment: .leading, spacing: 0) {
      Text(name)
        .font(.body)
        .lineLimit(1)
        .shimmer(isActive: isBusy)
      if let subtitle {
        Text(subtitle)
          .font(.footnote)
          .foregroundStyle(accent.shapeStyle(emphasized: backgroundProminence == .increased))
          .lineLimit(1)
      }
    }
  }
}

private struct IconView: View {
  let isFolder: Bool
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
  let icon: SidebarPullRequestIcon
  let checkBadgeState: SidebarCheckBadgeState?
  let rowState: IconRowState
  // `==` ignores @Environment; SwiftUI tracks env changes separately.
  @Environment(\.backgroundProminence) private var backgroundProminence

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.isFolder == rhs.isFolder
      && lhs.icon == rhs.icon
      && lhs.checkBadgeState == rhs.checkBadgeState
      && lhs.rowState == rhs.rowState
  }

  private var isEmphasized: Bool {
    backgroundProminence == .increased
  }

  private var isSystemImage: Bool {
    rowState != .idle || isFolder
  }

  private var folderIconName: String {
    switch rowState {
    case .pending: return "truck.box.badge.clock"
    case .archiving: return "archivebox"
    case .deleting: return "trash"
    case .idle: return "folder"
    }
  }

  private var folderColor: AnyShapeStyle {
    guard !isEmphasized else { return AnyShapeStyle(.secondary) }
    switch rowState {
    case .pending: return AnyShapeStyle(.blue)
    case .archiving: return AnyShapeStyle(.orange)
    case .deleting: return AnyShapeStyle(.red)
    case .idle: return AnyShapeStyle(.secondary)
    }
  }

  private var accessibilityLabel: String? {
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
          MultiColorPingDot(
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

private struct MultiColorPingDot: View {
  let colors: [RepositoryColor]
  let isEmphasized: Bool
  let size: CGFloat
  let showsSolidCenter: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var uniqueColors: [Color] {
    guard !isEmphasized else { return [.primary] }
    var seen = Set<RepositoryColor>()
    return colors.compactMap { tint in
      guard seen.insert(tint).inserted else { return nil }
      return tint.color
    }
  }

  var body: some View {
    let resolved = uniqueColors
    if resolved.count <= 1 {
      PingDot(
        color: resolved.first ?? .green,
        size: size,
        showsSolidCenter: showsSolidCenter
      )
    } else if reduceMotion {
      StaticDot(color: resolved[0], size: size, showsSolidCenter: showsSolidCenter)
    } else {
      CyclingDot(colors: resolved, size: size, showsSolidCenter: showsSolidCenter)
    }
  }
}

private struct StaticDot: View {
  let color: Color
  let size: CGFloat
  let showsSolidCenter: Bool

  var body: some View {
    ZStack {
      Circle()
        .stroke(color, lineWidth: 1)
        .frame(width: size, height: size)
        .opacity(0.6)
      if showsSolidCenter {
        Circle()
          .fill(color)
          .frame(width: size, height: size)
      }
    }
    .accessibilityLabel("Run script active")
  }
}

private struct CyclingDot: View {
  let colors: [Color]
  let size: CGFloat
  let showsSolidCenter: Bool

  var body: some View {
    TimelineView(.periodic(from: .now, by: 2.0)) { timeline in
      let index = Self.colorIndex(for: timeline.date, count: colors.count)
      let color = colors[index]
      ZStack {
        PingRing(color: color, size: size)
        if showsSolidCenter {
          Circle()
            .fill(color)
            .frame(width: size, height: size)
        }
      }
      .animation(.easeInOut(duration: 0.6), value: index)
    }
    .accessibilityLabel("Run script active")
  }

  private static func colorIndex(for date: Date, count: Int) -> Int {
    guard count > 0 else { return 0 }
    let seconds = Int(date.timeIntervalSinceReferenceDate)
    return (seconds / 2) % count
  }
}

private struct PingDot: View {
  let color: Color
  let size: CGFloat
  let showsSolidCenter: Bool

  var body: some View {
    ZStack {
      PingRing(color: color, size: size)
      if showsSolidCenter {
        Circle()
          .fill(color)
          .frame(width: size, height: size)
      }
    }
    .accessibilityLabel("Run script active")
  }
}

private struct PingRing: View {
  let color: Color
  let size: CGFloat

  var body: some View {
    Circle()
      .stroke(color, lineWidth: 1)
      .frame(width: size, height: size)
      .phaseAnimator([false, true]) { content, expanded in
        content
          .scaleEffect(expanded ? 2 : 1)
          .opacity(expanded ? 0 : 0.6)
      } animation: { expanded in
        expanded ? .easeOut(duration: 1) : .linear(duration: 0.001)
      }
  }
}

private nonisolated let notificationEnvironmentLogger = SupaLogger("Notifications")

extension EnvironmentValues {
  @Entry var focusNotificationAction: (WorktreeTerminalNotification) -> Void = { _ in
    notificationEnvironmentLogger.warning("focusNotificationAction called but was never set in the environment.")
  }
}
