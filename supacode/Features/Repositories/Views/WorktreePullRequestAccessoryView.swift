import SwiftUI

struct WorktreePullRequestDisplay {
  let pullRequest: ForgePullRequest?
  let pullRequestState: String?
  let pullRequestBadgeStyle: (text: String, color: Color)?

  init(worktreeName: String, pullRequest: ForgePullRequest?) {
    let matchesWorktree =
      if let pullRequest {
        pullRequest.headRefName == nil || pullRequest.headRefName == worktreeName
      } else {
        false
      }
    let displayPullRequest = matchesWorktree ? pullRequest : nil
    let pullRequestState = displayPullRequest?.displayStateBadge
    let pullRequestNumber = displayPullRequest?.number
    // Merge-queue is GitHub-only; GitLab MRs never report a queued state in v1.
    let isQueued = displayPullRequest?.github.map { PullRequestMergeQueueStatus(pullRequest: $0) != nil } ?? false
    self.pullRequest = displayPullRequest
    self.pullRequestState = pullRequestState
    self.pullRequestBadgeStyle = PullRequestBadgeStyle.style(
      state: pullRequestState,
      number: pullRequestNumber,
      isQueued: isQueued
    )
  }
}

struct WorktreePullRequestAccessoryView: View {
  let display: WorktreePullRequestDisplay

  var body: some View {
    if let pullRequestBadgeStyle = display.pullRequestBadgeStyle,
      let pullRequest = display.pullRequest
    {
      switch pullRequest {
      case .github(let githubPullRequest):
        PullRequestChecksPopoverButton(
          pullRequest: githubPullRequest
        ) {
          PullRequestBadgeView(text: pullRequestBadgeStyle.text, color: pullRequestBadgeStyle.color)
        }
      case .gitlab:
        // v1 GitLab: render the badge without a check-rollup popover. Pipeline status display
        // is a separate v1 surface (sidebar status dot / detail view).
        PullRequestBadgeView(text: pullRequestBadgeStyle.text, color: pullRequestBadgeStyle.color)
      }
    }
  }
}
