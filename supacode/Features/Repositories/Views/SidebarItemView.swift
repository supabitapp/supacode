import SupacodeSettingsShared
import SwiftUI

struct SidebarItemView: View {
  let kind: SidebarItemModel.Kind
  let name: String
  let subtitle: String?
  let worktreeColor: WorktreeColor
  let isBusy: Bool
  let gitIconName: String
  let gitIconColor: AnyShapeStyle
  let isArchiving: Bool
  let isDeleting: Bool
  let isPending: Bool
  let info: WorktreeInfoEntry?
  let pullRequestBadgeText: String?
  let showsPullRequestInfo: Bool
  let runningScriptColors: [TerminalTabTintColor]
  let showsNotificationIndicator: Bool
  let notifications: [WorktreeTerminalNotification]
  let shortcutHint: String?
  let checkBadgeState: CheckBadgeState?

  enum WorktreeColor {
    case `default`
    case main
    case pinned
  }

  enum CheckBadgeState {
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

  init(
    row: SidebarItemModel,
    displayMode: WorktreeRowDisplayMode,
    hideSubtitle: Bool,
    hideSubtitleOnMatch: Bool,
    showsPullRequestInfo: Bool,
    runningScriptColors: [TerminalTabTintColor],
    isTaskRunning: Bool,
    showsNotificationIndicator: Bool,
    notifications: [WorktreeTerminalNotification],
    shortcutHint: String?
  ) {
    self.kind = row.kind
    self.isArchiving = row.isArchiving
    self.isDeleting = row.isDeleting
    self.isPending = row.isPending
    self.info = row.info
    self.showsPullRequestInfo = showsPullRequestInfo
    self.runningScriptColors = runningScriptColors
    self.showsNotificationIndicator = showsNotificationIndicator
    self.notifications = notifications
    self.shortcutHint = shortcutHint
    self.isBusy = row.isArchiving || row.isDeleting || row.isPending || isTaskRunning

    // Worktree color.
    self.worktreeColor =
      if row.isMainWorktree { .main } else if row.isPinned { .pinned } else { .default }

    // Folders have no branch / no PR — show the folder name alone,
    // ignore display-mode and PR computation entirely.
    if row.kind == .folder {
      self.name = row.name
      self.subtitle = nil
      self.pullRequestBadgeText = nil
      self.gitIconName = "folder"
      self.gitIconColor = AnyShapeStyle(.secondary)
      self.checkBadgeState = nil
      return
    }

    // Title and subtitle based on display mode.
    let branchName = row.name
    let worktreeName = Self.worktreeName(for: row)
    let effectiveWorktreeName = worktreeName.isEmpty ? branchName : worktreeName
    switch displayMode {
    case .branchFirst:
      self.name = branchName
    case .worktreeFirst:
      self.name = effectiveWorktreeName
    }

    // Hide subtitle when the worktree name matches the branch name's last path component.
    let branchLastComponent = branchName.split(separator: "/").last.map(String.init) ?? branchName
    let isMatch = effectiveWorktreeName == branchLastComponent
    let rawSubtitle = displayMode == .branchFirst ? effectiveWorktreeName : branchName
    if hideSubtitle || (hideSubtitleOnMatch && isMatch) {
      self.subtitle = nil
    } else {
      self.subtitle = rawSubtitle
    }

    // Pull request display.
    let prDisplay = WorktreePullRequestDisplay(
      worktreeName: row.name,
      pullRequest: showsPullRequestInfo ? row.info?.pullRequest : nil
    )
    self.pullRequestBadgeText = prDisplay.pullRequestBadgeStyle?.text
    if let pullRequest = prDisplay.pullRequest {
      switch pullRequest.state.uppercased() {
      case "MERGED":
        self.gitIconName = "git-merge"
        self.gitIconColor = AnyShapeStyle(.purple)
      case "CLOSED":
        self.gitIconName = "git-pull-request-closed"
        self.gitIconColor = AnyShapeStyle(.red)
      case "OPEN" where pullRequest.isDraft:
        self.gitIconName = "git-pull-request-draft"
        self.gitIconColor = AnyShapeStyle(.tertiary)
      case "OPEN":
        self.gitIconName = "git-pull-request"
        self.gitIconColor = AnyShapeStyle(.green)
      default:
        self.gitIconName = "git-branch"
        self.gitIconColor = AnyShapeStyle(.secondary)
      }
    } else {
      self.gitIconName = "git-branch"
      self.gitIconColor = AnyShapeStyle(.secondary)
    }

    // Check badge for PRs with status checks.
    if let checks = prDisplay.pullRequest?.statusCheckRollup?.checks,
      !checks.isEmpty
    {
      let breakdown = PullRequestCheckBreakdown(checks: checks)
      if breakdown.failed > 0 {
        self.checkBadgeState = .failing
      } else if breakdown.inProgress > 0 || breakdown.expected > 0 {
        self.checkBadgeState = .inProgress
      } else {
        self.checkBadgeState = .passing
      }
    } else {
      self.checkBadgeState = nil
    }
  }

  private static func worktreeName(for row: SidebarItemModel) -> String {
    guard !row.isMainWorktree else { return "Default" }
    if row.id.contains("/") {
      let pathName = URL(fileURLWithPath: row.id).lastPathComponent
      guard pathName.isEmpty else { return pathName }
    }
    if !row.detail.isEmpty, row.detail != "." {
      let detailName = URL(fileURLWithPath: row.detail).lastPathComponent
      guard detailName.isEmpty || detailName == "." else { return detailName }
    }
    return row.name
  }

  var body: some View {
    Label {
      HStack(spacing: 8) {
        TitleView(
          name: name,
          subtitle: subtitle,
          worktreeColor: worktreeColor,
          isBusy: isBusy
        )
        Spacer(minLength: 0)
        TrailingView(
          shortcutHint: shortcutHint,
          info: info,
          showsPullRequestInfo: showsPullRequestInfo,
          pullRequestBadgeText: pullRequestBadgeText,
          runningScriptColors: runningScriptColors,
          showsNotificationIndicator: showsNotificationIndicator,
          notifications: notifications
        )
      }
    } icon: {
      IconView(
        kind: kind,
        isArchiving: isArchiving,
        isDeleting: isDeleting,
        isPending: isPending,
        gitIconName: gitIconName,
        gitIconColor: gitIconColor,
        checkBadgeState: checkBadgeState
      )
    }
    .labelStyle(.verticallyCentered)
    .listRowInsets(.trailing, 4)
    .listRowInsets(.vertical, 6)
  }
}

// MARK: - Title.

private struct TitleView: View {
  let name: String
  let subtitle: String?
  let worktreeColor: SidebarItemView.WorktreeColor
  let isBusy: Bool
  @Environment(\.backgroundProminence) private var backgroundProminence

  private var resolvedWorktreeColor: AnyShapeStyle {
    guard backgroundProminence != .increased else { return AnyShapeStyle(.secondary) }
    return switch worktreeColor {
    case .main: AnyShapeStyle(.yellow)
    case .pinned: AnyShapeStyle(.orange)
    case .default: AnyShapeStyle(.tertiary)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(name)
        .font(.body)
        .lineLimit(1)
        .shimmer(isActive: isBusy)
      if let subtitle {
        Text(subtitle)
          .font(.footnote)
          .foregroundStyle(resolvedWorktreeColor)
          .lineLimit(1)
      }
    }
  }
}

// MARK: - Icon.

private struct IconView: View {
  let kind: SidebarItemModel.Kind
  let isArchiving: Bool
  let isDeleting: Bool
  let isPending: Bool
  let gitIconName: String
  let gitIconColor: AnyShapeStyle
  let checkBadgeState: SidebarItemView.CheckBadgeState?
  @Environment(\.backgroundProminence) private var backgroundProminence

  private var isEmphasized: Bool {
    backgroundProminence == .increased
  }

  private var resolvedName: String {
    if isPending { return "truck.box.badge.clock" }
    if isArchiving { return "archivebox" }
    if isDeleting { return "trash" }
    return gitIconName
  }

  private var resolvedColor: AnyShapeStyle {
    guard !isEmphasized else { return AnyShapeStyle(.secondary) }
    if isPending { return AnyShapeStyle(.blue) }
    if isArchiving { return AnyShapeStyle(.orange) }
    if isDeleting { return AnyShapeStyle(.red) }
    return gitIconColor
  }

  // Folder idle rendering uses the SF Symbol "folder"; busy-state
  // overrides (pending/archiving/deleting) already use system images.
  private var isSystemImage: Bool {
    isPending || isArchiving || isDeleting || kind == .folder
  }

  private var isIdleFolder: Bool {
    kind == .folder && !isPending && !isArchiving && !isDeleting
  }

  private var accessibilityLabel: String? {
    if isPending { return "Creating" }
    if isArchiving { return "Archiving" }
    if isDeleting { return "Deleting" }
    return nil
  }

  var body: some View {
    Group {
      if isSystemImage {
        Image(systemName: resolvedName)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .fontWeight(.semibold)
      } else {
        Image(resolvedName)
          .renderingMode(.template)
          .resizable()
          .aspectRatio(contentMode: .fit)
      }
    }
    .foregroundStyle(resolvedColor)
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

private struct TrailingView: View {
  let shortcutHint: String?
  let info: WorktreeInfoEntry?
  let showsPullRequestInfo: Bool
  let pullRequestBadgeText: String?
  let runningScriptColors: [TerminalTabTintColor]
  let showsNotificationIndicator: Bool
  let notifications: [WorktreeTerminalNotification]

  var body: some View {
    if let shortcutHint {
      Text(shortcutHint)
        .font(.caption)
        .foregroundStyle(.secondary)
    } else {
      HStack(spacing: 6) {
        DiffStatsView(info: info)
        if showsPullRequestInfo, let pullRequestBadgeText {
          Text(pullRequestBadgeText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .transition(.blurReplace)
        }
        StatusIndicator(
          runningScriptColors: runningScriptColors,
          showsNotificationIndicator: showsNotificationIndicator,
          notifications: notifications
        )
      }
    }
  }
}

// MARK: - Diff stats.

private struct DiffStatsView: View {
  let info: WorktreeInfoEntry?
  @Environment(\.backgroundProminence) private var backgroundProminence

  var body: some View {
    let isEmphasized = backgroundProminence == .increased
    if let added = info?.addedLines, let removed = info?.removedLines, added + removed > 0 {
      HStack(spacing: 2) {
        Text("+\(added)")
          .foregroundStyle(isEmphasized ? AnyShapeStyle(.secondary) : AnyShapeStyle(.green))
        Text("-\(removed)")
          .foregroundStyle(isEmphasized ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
      }
      .font(.caption)
      .monospacedDigit()
      .transition(.blurReplace)
    }
  }
}

// MARK: - Status indicator.

private struct StatusIndicator: View {
  let runningScriptColors: [TerminalTabTintColor]
  let showsNotificationIndicator: Bool
  let notifications: [WorktreeTerminalNotification]
  @Environment(\.backgroundProminence) private var backgroundProminence
  @Environment(\.focusNotificationAction) private var focusNotificationAction: (WorktreeTerminalNotification) -> Void

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
  let colors: [TerminalTabTintColor]
  let isEmphasized: Bool
  let size: CGFloat
  let showsSolidCenter: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Unique, ordered colors derived from the input.
  private var uniqueColors: [Color] {
    guard !isEmphasized else { return [.primary] }
    var seen = Set<TerminalTabTintColor>()
    return colors.compactMap { tint in
      guard seen.insert(tint).inserted else { return nil }
      return tint.color
    }
  }

  var body: some View {
    let resolved = uniqueColors
    if resolved.count <= 1 {
      PingDot(
        style: resolved.first.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.green),
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
  @State private var isPinging = false

  var body: some View {
    TimelineView(.periodic(from: .now, by: 2.0)) { timeline in
      let index = Self.colorIndex(for: timeline.date, count: colors.count)
      ZStack {
        Circle()
          .stroke(colors[index], lineWidth: 1)
          .frame(width: size, height: size)
          .scaleEffect(isPinging ? 2 : 1)
          .opacity(isPinging ? 0 : 0.6)
          .animation(.easeOut(duration: 1).repeatForever(autoreverses: false), value: isPinging)
        if showsSolidCenter {
          Circle()
            .fill(colors[index])
            .frame(width: size, height: size)
        }
      }
      .animation(.easeInOut(duration: 0.6), value: index)
    }
    .accessibilityLabel("Run script active")
    .task { isPinging = true }
  }

  private static func colorIndex(for date: Date, count: Int) -> Int {
    guard count > 0 else { return 0 }
    let seconds = Int(date.timeIntervalSinceReferenceDate)
    return (seconds / 2) % count
  }
}

// MARK: - Pulsing dot.

private struct PingDot<S: ShapeStyle>: View {
  let style: S
  let size: CGFloat
  let showsSolidCenter: Bool
  @State private var isPinging = false

  var body: some View {
    ZStack {
      Circle()
        .stroke(style, lineWidth: 1)
        .frame(width: size, height: size)
        .scaleEffect(isPinging ? 2 : 1)
        .opacity(isPinging ? 0 : 0.6)
        .animation(.easeOut(duration: 1).repeatForever(autoreverses: false), value: isPinging)
      if showsSolidCenter {
        Circle()
          .fill(style)
          .frame(width: size, height: size)
      }
    }
    .accessibilityLabel("Run script active")
    .task { isPinging = true }
  }
}

// MARK: - Focus notification environment.

private nonisolated let notificationEnvironmentLogger = SupaLogger("Notifications")

extension EnvironmentValues {
  @Entry var focusNotificationAction: (WorktreeTerminalNotification) -> Void = { _ in
    notificationEnvironmentLogger.warning("focusNotificationAction called but was never set in the environment.")
  }
}
