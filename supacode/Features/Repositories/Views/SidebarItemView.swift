import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

struct SidebarItemView: View {
  let kind: SidebarItemModel.Kind
  let worktreeID: Worktree.ID
  let worktreeName: String
  let terminalManager: WorktreeTerminalManager
  let store: StoreOf<RepositoriesFeature>
  let name: String
  let subtitle: String?
  let accent: WorktreeAccent
  let isLifecycleBusy: Bool
  let status: SidebarItemModel.Status
  let showsPullRequestInfo: Bool
  let shortcutHint: String?

  init(
    row: SidebarItemModel,
    terminalManager: WorktreeTerminalManager,
    store: StoreOf<RepositoriesFeature>,
    displayMode: WorktreeRowDisplayMode,
    hideSubtitle: Bool,
    hideSubtitleOnMatch: Bool,
    showsPullRequestInfo: Bool,
    shortcutHint: String?
  ) {
    self.kind = row.kind
    self.worktreeID = row.id
    self.worktreeName = row.name
    self.terminalManager = terminalManager
    self.store = store
    self.status = row.status
    self.showsPullRequestInfo = showsPullRequestInfo
    self.shortcutHint = shortcutHint
    self.isLifecycleBusy = row.isArchiving || row.isDeleting || row.isPending

    self.accent = row.accent

    if row.kind == .folder {
      self.name = row.name
      self.subtitle = nil
      return
    }

    let branchName = row.name
    let worktreeName = row.sidebarDisplayName ?? "Default"
    let effectiveWorktreeName = worktreeName.isEmpty ? branchName : worktreeName
    switch displayMode {
    case .branchFirst:
      self.name = branchName
    case .worktreeFirst:
      self.name = effectiveWorktreeName
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

  var body: some View {
    Label {
      HStack(spacing: 8) {
        TitleView(
          worktreeID: worktreeID,
          terminalManager: terminalManager,
          name: name,
          subtitle: subtitle,
          accent: accent,
          isLifecycleBusy: isLifecycleBusy
        )
        Spacer(minLength: 0)
        TrailingView(
          worktreeID: worktreeID,
          worktreeName: worktreeName,
          terminalManager: terminalManager,
          store: store,
          shortcutHint: shortcutHint,
          showsPullRequestInfo: showsPullRequestInfo
        )
      }
    } icon: {
      IconView(
        kind: kind,
        worktreeID: worktreeID,
        worktreeName: worktreeName,
        store: store,
        showsPullRequestInfo: showsPullRequestInfo,
        status: status
      )
    }
    .labelStyle(.verticallyCentered)
    .listRowInsets(.trailing, 4)
    .listRowInsets(.vertical, 6)
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

// MARK: - Title.

private struct TitleView: View {
  let worktreeID: Worktree.ID
  let terminalManager: WorktreeTerminalManager
  let name: String
  let subtitle: String?
  let accent: WorktreeAccent
  let isLifecycleBusy: Bool
  @Environment(\.backgroundProminence) private var backgroundProminence

  var body: some View {
    // Scoped here so taskStatus's agent-presence read doesn't invalidate the whole row.
    let isTaskRunning = terminalManager.stateIfExists(for: worktreeID)?.taskStatus == .running
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

// MARK: - Icon.

/// Owns the `worktreeInfo` PR read for its row. `IconContent` is `Equatable`
/// so rows whose PR state didn't change skip body work even when the
/// observable dict invalidates every leaf.
private struct IconView: View {
  let kind: SidebarItemModel.Kind
  let worktreeID: Worktree.ID
  let worktreeName: String
  let store: StoreOf<RepositoriesFeature>
  let showsPullRequestInfo: Bool
  let status: SidebarItemModel.Status

  var body: some View {
    let rawPullRequest = store.state.worktreeInfo(for: worktreeID)?.pullRequest
    // Route through WorktreePullRequestDisplay so the icon respects the
    // same `matchesWorktree` filter the badge uses; otherwise renamed
    // branches can render the icon for a PR the badge text suppresses.
    let display = WorktreePullRequestDisplay(
      worktreeName: worktreeName,
      pullRequest: showsPullRequestInfo ? rawPullRequest : nil,
    )
    IconContent(
      kind: kind,
      icon: SidebarPullRequestIcon.resolve(display.pullRequest),
      checkBadgeState: resolveCheckBadgeState(display.pullRequest),
      rowState: IconRowState(status),
    )
    .equatable()
  }
}

/// Coarser-than-`Status` enum that strips the `.deleting(inTerminal:)` associated
/// value the icon doesn't render. Lets `IconContent.==` ignore in-terminal flips
/// since the trash glyph is identical either way.
enum IconRowState: Equatable {
  case idle
  case pending
  case archiving
  case deleting

  init(_ status: SidebarItemModel.Status) {
    switch status {
    case .idle: self = .idle
    case .pending: self = .pending
    case .archiving: self = .archiving
    case .deleting: self = .deleting
    }
  }
}

private struct IconContent: View, Equatable {
  let kind: SidebarItemModel.Kind
  let icon: SidebarPullRequestIcon
  let checkBadgeState: SidebarCheckBadgeState?
  let rowState: IconRowState
  // The `==` below deliberately ignores the @Environment property; SwiftUI
  // tracks environment separately and re-runs body on env changes even when
  // the Equatable comparison returns true. Don't add it to ==.
  @Environment(\.backgroundProminence) private var backgroundProminence

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.kind == rhs.kind
      && lhs.icon == rhs.icon
      && lhs.checkBadgeState == rhs.checkBadgeState
      && lhs.rowState == rhs.rowState
  }

  private var isEmphasized: Bool {
    backgroundProminence == .increased
  }

  private var isSystemImage: Bool {
    rowState != .idle || kind == .folder
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

// MARK: - Trailing.

/// Reads every row-scoped observable up front (diff stats, PR, agents, scripts,
/// notifications) and conditionally includes each child. Keeps `HStack(spacing:)`
/// from reserving trailing space when a child would resolve to an empty body.
/// Each rendered leaf is value-only and `Equatable` so the actual draw work is
/// still skipped when the underlying values haven't changed.
private struct TrailingView: View {
  let worktreeID: Worktree.ID
  let worktreeName: String
  let terminalManager: WorktreeTerminalManager
  let store: StoreOf<RepositoriesFeature>
  let shortcutHint: String?
  let showsPullRequestInfo: Bool

  var body: some View {
    if let shortcutHint {
      Text(shortcutHint)
        .font(.caption)
        .foregroundStyle(.secondary)
    } else {
      let info = store.state.worktreeInfo(for: worktreeID)
      let display = WorktreePullRequestDisplay(
        worktreeName: worktreeName,
        pullRequest: showsPullRequestInfo ? info?.pullRequest : nil,
      )
      let prText = display.pullRequestBadgeStyle?.text
      let agents = terminalManager.agentsForSurfaces(
        terminalManager.surfaceIDs(forWorktreeID: worktreeID),
      )
      let scriptColors = store.state.runningScriptColors(for: worktreeID)
      let showsNotificationIndicator = terminalManager.hasUnseenNotifications(for: worktreeID)
      let notifications = terminalManager.stateIfExists(for: worktreeID)?.notifications ?? []
      let added = info?.addedLines ?? 0
      let removed = info?.removedLines ?? 0
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
  // `==` ignores the @Environment property; SwiftUI tracks environment separately
  // and re-runs body on env changes even when Equatable returns true.
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

// MARK: - Status indicator.

private struct StatusIndicator: View, Equatable {
  let runningScriptColors: [RepositoryColor]
  let showsNotificationIndicator: Bool
  let notifications: [WorktreeTerminalNotification]
  // `==` ignores @Environment values; SwiftUI handles env invalidation separately.
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

// MARK: - Multi-color ping dot.

/// Displays a pulsing dot that cycles through multiple script tint
/// colors when more than one script is running. Falls back to the
/// single-color pulsing behavior when only one color is present.
private struct MultiColorPingDot: View {
  let colors: [RepositoryColor]
  let isEmphasized: Bool
  let size: CGFloat
  let showsSolidCenter: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Unique, ordered colors derived from the input.
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
      // Show a static dot with the first color when motion is reduced.
      StaticDot(color: resolved[0], size: size, showsSolidCenter: showsSolidCenter)
    } else {
      CyclingDot(colors: resolved, size: size, showsSolidCenter: showsSolidCenter)
    }
  }
}

/// Static dot used when accessibility reduce-motion is enabled.
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

/// Animated dot that smoothly cycles through the provided colors.
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

// MARK: - Pulsing dot.

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

/// Expanding, fading ring driven by `phaseAnimator` rather than
/// `.repeatForever` so SwiftUI can pause the timeline when the view
/// is occluded and so parent re-evaluations don't restart the cycle.
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
        // Snap back to the seed phase instantly, then ease out the
        // expansion: yields a non-autoreversing ping without the
        // always-on `.repeatForever` animation driver.
        expanded ? .easeOut(duration: 1) : .linear(duration: 0.001)
      }
  }
}

// MARK: - Focus notification environment.

private nonisolated let notificationEnvironmentLogger = SupaLogger("Notifications")

extension EnvironmentValues {
  @Entry var focusNotificationAction: (WorktreeTerminalNotification) -> Void = { _ in
    notificationEnvironmentLogger.warning("focusNotificationAction called but was never set in the environment.")
  }
}
