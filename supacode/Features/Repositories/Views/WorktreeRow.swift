import AppKit
import SwiftUI

struct WorktreeRow: View {
  let name: String
  let worktreeName: String
  let info: WorktreeInfoEntry?
  let showsPullRequestInfo: Bool
  let isHovered: Bool
  let isPinned: Bool
  let isMainWorktree: Bool
  let isLoading: Bool
  let taskStatus: WorktreeTaskStatus?
  let isRunScriptRunning: Bool
  let showsNotificationIndicator: Bool
  let notifications: [WorktreeTerminalNotification]
  let onFocusNotification: (WorktreeTerminalNotification) -> Void
  let shortcutHint: String?
  let pinAction: (() -> Void)?
  let isSelected: Bool
  let archiveAction: (() -> Void)?
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let showsSpinner = isLoading || taskStatus == .running
    let branchIconName = isMainWorktree ? "star.fill" : (isPinned ? "pin.fill" : "arrow.triangle.branch")
    let display = WorktreePullRequestDisplay(
      worktreeName: name,
      pullRequest: showsPullRequestInfo ? info?.pullRequest : nil
    )
    let displayAddedLines = info?.addedLines
    let displayRemovedLines = info?.removedLines
    let mergeReadiness = pullRequestMergeReadiness(for: display.pullRequest)
    let hasChangeCounts = displayAddedLines != nil && displayRemovedLines != nil
    let archiveShortcut = KeyboardShortcut(.delete, modifiers: .command).display
    let showsPullRequestTag = display.pullRequest != nil && display.pullRequestBadgeStyle != nil
    let nameColor = colorScheme == .dark ? Color.white : Color.primary
    let detailText = worktreeName.isEmpty ? name : worktreeName
    VStack(alignment: .leading, spacing: 2) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        ZStack {
          if showsNotificationIndicator {
            NotificationPopoverButton(
              notifications: notifications,
              onFocusNotification: onFocusNotification
            ) {
              Image(systemName: "bell.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityLabel("Unread notifications")
            }
            .opacity(showsSpinner ? 0 : 1)
          } else {
            Image(systemName: branchIconName)
              .font(.caption)
              .foregroundStyle(.secondary)
              .opacity(showsSpinner ? 0 : 1)
              .accessibilityHidden(true)
          }
          if showsSpinner {
            ProgressView()
              .controlSize(.small)
          }
        }
        .frame(width: 16, height: 16)
        .alignmentGuide(.firstTextBaseline) { _ in
          bodyFont.ascender
        }
        Text(name)
          .font(.body)
          .foregroundStyle(nameColor)
          .lineLimit(1)
        Spacer(minLength: 4)
        if isRunScriptRunning {
          Image(systemName: "play.fill")
            .font(.caption)
            .foregroundStyle(isSelected ? Color.primary : Color.green)
            .help("Run script active")
            .accessibilityLabel("Run script active")
        }
        if hasChangeCounts, let displayAddedLines, let displayRemovedLines {
          WorktreeRowChangeCountView(
            addedLines: displayAddedLines,
            removedLines: displayRemovedLines,
            isSelected: isSelected
          )
        }
        if isHovered {
          Button {
            pinAction?()
          } label: {
            Image(systemName: isPinned ? "pin.slash" : "pin")
              .contentTransition(.symbolEffect(.replace))
              .accessibilityLabel(isPinned ? "Unpin worktree" : "Pin worktree")
          }
          .buttonStyle(.plain)
          .help(isPinned ? "Unpin" : "Pin to top")
          .disabled(pinAction == nil)
          Button {
            archiveAction?()
          } label: {
            Image(systemName: "archivebox")
              .accessibilityLabel("Archive worktree")
          }
          .buttonStyle(.plain)
          .help("Archive Worktree (\(archiveShortcut))")
          .disabled(archiveAction == nil)
        }
      }
      WorktreeRowInfoView(
        worktreeName: detailText,
        showsPullRequestTag: showsPullRequestTag,
        pullRequestNumber: display.pullRequest?.number,
        pullRequestState: display.pullRequestState,
        mergeReadiness: mergeReadiness,
        isSelected: isSelected,
        shortcutHint: shortcutHint
      )
      .padding(.leading, 22)
    }
    .padding(.horizontal, 2)
    .padding(.vertical, 4)
    .frame(maxWidth: .infinity, minHeight: worktreeRowHeight, alignment: .center)
  }

  private func pullRequestMergeReadiness(
    for pullRequest: GithubPullRequest?
  ) -> PullRequestMergeReadiness? {
    guard let pullRequest, pullRequest.state.uppercased() == "OPEN" else {
      return nil
    }
    return PullRequestMergeReadiness(pullRequest: pullRequest)
  }

  private var bodyFont: NSFont {
    NSFont.preferredFont(forTextStyle: .body)
  }

  private var worktreeRowHeight: CGFloat {
    56
  }
}

private struct WorktreeRowInfoView: View {
  let worktreeName: String
  let showsPullRequestTag: Bool
  let pullRequestNumber: Int?
  let pullRequestState: String?
  let mergeReadiness: PullRequestMergeReadiness?
  let isSelected: Bool
  let shortcutHint: String?

  var body: some View {
    HStack(spacing: 4) {
      summaryText
        .lineLimit(2)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
      Spacer(minLength: 0)
      if let shortcutHint {
        ShortcutHintView(text: shortcutHint, color: .secondary)
      }
    }
    .font(.caption)
    .frame(minHeight: 14)
  }

  private var summaryText: Text {
    var result = AttributedString()
    func appendSeparator() {
      if !result.characters.isEmpty {
        var sep = AttributedString(" \u{2022} ")
        sep.foregroundColor = .secondary
        result.append(sep)
      }
    }
    if !worktreeName.isEmpty {
      var segment = AttributedString(worktreeName)
      segment.foregroundColor = .secondary
      result.append(segment)
    }
    if showsPullRequestTag, let pullRequestNumber {
      appendSeparator()
      var segment = AttributedString("PR #\(pullRequestNumber)")
      segment.foregroundColor = .secondary
      result.append(segment)
    }
    if pullRequestState == "MERGED" {
      appendSeparator()
      var segment = AttributedString("Merged")
      segment.foregroundColor = isSelected ? .secondary : PullRequestBadgeStyle.mergedColor
      result.append(segment)
    } else if let mergeReadiness {
      appendSeparator()
      var segment = AttributedString(mergeReadiness.label)
      segment.foregroundColor = isSelected ? .secondary : (mergeReadiness.isBlocking ? .red : .green)
      result.append(segment)
    }
    return Text(result)
  }
}

private struct WorktreeRowChangeCountView: View {
  let addedLines: Int
  let removedLines: Int
  let isSelected: Bool

  var body: some View {
    HStack(spacing: 4) {
      Text("+\(addedLines)")
        .foregroundStyle(isSelected ? Color.secondary : Color.green)
      Text("-\(removedLines)")
        .foregroundStyle(isSelected ? Color.secondary : Color.red)
    }
    .font(.caption)
    .lineLimit(1)
    .padding(.horizontal, 4)
    .padding(.vertical, 2)
    .overlay {
      RoundedRectangle(cornerRadius: 4, style: .continuous)
        .stroke(isSelected ? AnyShapeStyle(.secondary.opacity(0.3)) : AnyShapeStyle(.tertiary), lineWidth: 1)
    }
    .monospacedDigit()
  }
}
