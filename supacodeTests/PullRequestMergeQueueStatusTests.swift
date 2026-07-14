import SwiftUI
import Testing

@testable import supacode

@MainActor
struct PullRequestMergeQueueStatusTests {
  @Test func nilWhenNotQueued() {
    let pullRequest = makePullRequest(mergeStateStatus: "CLEAN")
    #expect(PullRequestMergeQueueStatus(pullRequest: pullRequest) == nil)
  }

  @Test func nilWhenQueuedMergeStateStatusButNoEntry() {
    // `MergeStateStatus` has no QUEUED member, so a queued PR always carries an entry. No entry, no status.
    let pullRequest = makePullRequest(mergeStateStatus: "QUEUED")
    #expect(PullRequestMergeQueueStatus(pullRequest: pullRequest) == nil)
  }

  @Test func surfacesPositionAndEstimatedTime() {
    let entry = GithubMergeQueueEntry(position: 2, estimatedTimeToMerge: 600, state: "QUEUED")
    let pullRequest = makePullRequest(mergeQueueEntry: entry)
    let status = PullRequestMergeQueueStatus(pullRequest: pullRequest)

    #expect(status?.position == 3)
    #expect(status?.positionLabel == "Position 3")
    // The abbreviated minute unit is format-version sensitive ("min" vs "mins"), so take the spelling from the
    // formatter and assert the magnitude ourselves.
    #expect(Self.tenMinutes.hasPrefix("10 "))
    #expect(status?.estimatedTimeLabel == "~\(Self.tenMinutes) left")
    #expect(status?.detail == "Position 3 · ~\(Self.tenMinutes) left")
  }

  private static var tenMinutes: String {
    Duration.seconds(600)
      .formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
  }

  @Test func dropsEstimatedTimeWhenZeroOrMissing() {
    let entry = GithubMergeQueueEntry(position: 0, estimatedTimeToMerge: 0, state: "MERGEABLE")
    let pullRequest = makePullRequest(mergeQueueEntry: entry)
    let status = PullRequestMergeQueueStatus(pullRequest: pullRequest)

    #expect(status?.estimatedTimeLabel == nil)
    #expect(status?.detail == "Position 1")
  }

  @Test func rendersSubMinuteEstimateAsLessThanOneMinute() {
    let entry = GithubMergeQueueEntry(position: 0, estimatedTimeToMerge: 30, state: "QUEUED")
    let status = PullRequestMergeQueueStatus(pullRequest: makePullRequest(mergeQueueEntry: entry))

    #expect(status?.estimatedTimeLabel == "<1 min left")
    #expect(status?.detail == "Position 1 · <1 min left")
  }

  @Test func estimatedTimeLabelPinsTheOneMinuteBoundary() {
    let justUnder = GithubMergeQueueEntry(position: 0, estimatedTimeToMerge: 59, state: "QUEUED")
    let exactlyOne = GithubMergeQueueEntry(position: 0, estimatedTimeToMerge: 60, state: "QUEUED")

    #expect(
      PullRequestMergeQueueStatus(pullRequest: makePullRequest(mergeQueueEntry: justUnder))?.estimatedTimeLabel
        == "<1 min left")
    #expect(
      PullRequestMergeQueueStatus(pullRequest: makePullRequest(mergeQueueEntry: exactlyOne))?.estimatedTimeLabel
        == "~1 min left")
  }

  @Test func formatsMultiUnitEstimate() {
    let entry = GithubMergeQueueEntry(position: 0, estimatedTimeToMerge: 3660, state: "QUEUED")
    let label = PullRequestMergeQueueStatus(pullRequest: makePullRequest(mergeQueueEntry: entry))?.estimatedTimeLabel

    // Exact unit strings are locale/format-version sensitive; assert the shape, not the spelling.
    #expect(label?.hasPrefix("~") == true)
    #expect(label?.hasSuffix("left") == true)
    #expect(label?.contains("hr") == true)
  }

  @Test func summaryReflectsState() {
    #expect(summary(for: "QUEUED") == "In merge queue")
    #expect(summary(for: "AWAITING_CHECKS") == "Awaiting checks in merge queue")
    #expect(summary(for: "MERGEABLE") == "In merge queue")
    #expect(summary(for: "UNMERGEABLE") == "Cannot merge from queue")
    #expect(summary(for: "LOCKED") == "Merge queue locked")
    #expect(summary(for: "SOME_FUTURE_STATE") == "In merge queue")
  }

  @Test func ignoresStaleEntryOnMergedPR() {
    let entry = GithubMergeQueueEntry(position: 0, estimatedTimeToMerge: nil, state: "QUEUED")
    let pullRequest = makePullRequest(state: "MERGED", mergeQueueEntry: entry)
    #expect(PullRequestMergeQueueStatus(pullRequest: pullRequest) == nil)
  }

  @Test func ignoresEntryOnDraftPR() {
    let entry = GithubMergeQueueEntry(position: 0, estimatedTimeToMerge: nil, state: "QUEUED")
    let pullRequest = makePullRequest(isDraft: true, mergeQueueEntry: entry)
    #expect(PullRequestMergeQueueStatus(pullRequest: pullRequest) == nil)
  }

  @Test func toolbarBadgeIsBrownWhenQueued() {
    let entry = GithubMergeQueueEntry(position: 0, estimatedTimeToMerge: nil, state: "QUEUED")
    let queued = makePullRequest(mergeQueueEntry: entry)
    let open = makePullRequest(mergeStateStatus: "CLEAN")

    // The toolbar accessory badge tints brown to match the sidebar + popover.
    #expect(
      WorktreePullRequestDisplay(worktreeName: "feature", pullRequest: queued).pullRequestBadgeStyle?.color == .brown)
    #expect(
      WorktreePullRequestDisplay(worktreeName: "feature", pullRequest: open).pullRequestBadgeStyle?.color == .green)
  }

  @Test func sidebarIconResolvesQueued() {
    let entry = GithubMergeQueueEntry(position: 0, estimatedTimeToMerge: nil, state: "QUEUED")
    let queued = makePullRequest(mergeQueueEntry: entry)
    let open = makePullRequest(mergeStateStatus: "CLEAN")
    let draft = makePullRequest(isDraft: true, mergeQueueEntry: entry)

    #expect(SidebarPullRequestIcon.resolve(queued) == .queued)
    #expect(SidebarPullRequestIcon.resolve(open) == .open)
    // A draft is never in the merge queue; draft classification wins.
    #expect(SidebarPullRequestIcon.resolve(draft) == .draft)
  }

  private func summary(for entryState: String) -> String? {
    let entry = GithubMergeQueueEntry(position: 0, estimatedTimeToMerge: nil, state: entryState)
    return PullRequestMergeQueueStatus(pullRequest: makePullRequest(mergeQueueEntry: entry))?.summary
  }
}

private func makePullRequest(
  state: String = "OPEN",
  isDraft: Bool = false,
  mergeStateStatus: String? = nil,
  mergeQueueEntry: GithubMergeQueueEntry? = nil
) -> GithubPullRequest {
  GithubPullRequest(
    number: 1,
    title: "PR",
    state: state,
    additions: 0,
    deletions: 0,
    isDraft: isDraft,
    reviewDecision: nil,
    mergeable: nil,
    mergeStateStatus: mergeStateStatus,
    updatedAt: nil,
    url: "https://example.com/pull/1",
    headRefName: "feature",
    baseRefName: "main",
    commitsCount: 1,
    authorLogin: "khoi",
    statusCheckRollup: nil,
    mergeQueueEntry: mergeQueueEntry
  )
}
