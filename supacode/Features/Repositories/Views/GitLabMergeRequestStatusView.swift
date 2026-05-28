import SwiftUI

// v1 GitLab toolbar status: badge + title + pipeline ring. No merge / close / ready affordances.
struct GitLabMergeRequestStatusView: View {
  let mergeRequest: GitLabMergeRequest

  var body: some View {
    let badgeState = ForgePullRequest.gitlab(mergeRequest).displayStateBadge
    let style = PullRequestBadgeStyle.style(
      state: badgeState,
      number: mergeRequest.iid,
      isQueued: false
    )
    Button {
      guard let url = URL(string: mergeRequest.url) else { return }
      NSWorkspace.shared.open(url)
    } label: {
      HStack(spacing: 6) {
        if let style {
          PullRequestBadgeView(text: style.text, color: style.color)
            .layoutPriority(1)
        }
        if let pipeline = mergeRequest.pipelineStatus, pipeline != .unknown {
          GitLabPipelineRingView(status: pipeline)
        }
        Text(mergeRequest.title)
          .lineLimit(1)
          .font(.caption)
      }
    }
    .buttonStyle(.borderless)
    .help("Open merge request !\(mergeRequest.iid) on GitLab")
  }
}

private struct GitLabPipelineRingView: View {
  let status: GitLabPipelineStatus

  var body: some View {
    Image(systemName: symbolName)
      .foregroundStyle(color)
      .font(.caption)
      .accessibilityLabel(accessibilityLabel)
  }

  private var symbolName: String {
    if status.isSuccess { return "checkmark.circle.fill" }
    if status.isFailure { return "xmark.circle.fill" }
    if status.isInProgress { return "circle.dotted" }
    return "circle"
  }

  private var color: Color {
    if status.isSuccess { return .green }
    if status.isFailure { return .red }
    if status.isInProgress { return .yellow }
    return .secondary
  }

  private var accessibilityLabel: String {
    "Pipeline \(status.rawValue)"
  }
}
