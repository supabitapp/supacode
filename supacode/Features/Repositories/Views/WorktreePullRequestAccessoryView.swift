import SwiftUI

struct WorktreePullRequestDisplay {
  let pullRequest: ForgePullRequest?
  let pullRequestState: PullRequestState?
  let pullRequestBadgeStyle: (text: String, color: Color)?

  init(worktreeName: String, pullRequest: ForgePullRequest?) {
    let matchesWorktree =
      if let pullRequest {
        pullRequest.headRefName == nil || pullRequest.headRefName == worktreeName
      } else {
        false
      }
    let displayPullRequest = matchesWorktree ? pullRequest : nil
    let pullRequestState = displayPullRequest?.state
    let pullRequestNumber = displayPullRequest?.number
    let isQueued = displayPullRequest.map { PullRequestMergeQueueStatus(pullRequest: $0) != nil } ?? false
    self.pullRequest = displayPullRequest
    self.pullRequestState = pullRequestState
    self.pullRequestBadgeStyle = PullRequestBadgeStyle.style(
      state: pullRequestState,
      number: pullRequestNumber,
      isQueued: isQueued,
      numberSigil: displayPullRequest?.numberSigil ?? "#"
    )
  }
}

struct WorktreePullRequestAccessoryView: View {
  let display: WorktreePullRequestDisplay

  var body: some View {
    if let pullRequestBadgeStyle = display.pullRequestBadgeStyle,
      let pullRequest = display.pullRequest
    {
      PullRequestChecksPopoverButton(
        pullRequest: pullRequest
      ) {
        PullRequestBadgeView(text: pullRequestBadgeStyle.text, color: pullRequestBadgeStyle.color)
      }
    }
  }
}
