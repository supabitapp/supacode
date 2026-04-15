import Sharing
import SupacodeSettingsShared
import SwiftUI

struct PullRequestChecksPopoverView: View {
  let pullRequest: GithubPullRequest
  let checks: [GithubPullRequestStatusCheck]
  private let breakdown: PullRequestCheckBreakdown
  private let sortedChecks: [GithubPullRequestStatusCheck]
  @Environment(\.analyticsClient) private var analyticsClient
  @Environment(\.openURL) private var openURL
  @Shared(.settingsFile) private var settingsFile

  init(
    pullRequest: GithubPullRequest,
    checks: [GithubPullRequestStatusCheck]
  ) {
    self.pullRequest = pullRequest
    self.checks = checks
    self.breakdown = PullRequestCheckBreakdown(checks: checks)
    self.sortedChecks = checks.sorted {
      let left = Self.sortRank(for: $0.checkState)
      let right = Self.sortRank(for: $1.checkState)
      if left == right {
        return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
      }
      return left < right
    }
  }

  private var effectiveOpenPR: AppShortcut? {
    AppShortcuts.openPullRequest.effective(from: settingsFile.global.shortcutOverrides)
  }

  var body: some View {
    let pullRequestURL = URL(string: pullRequest.url)
    let stateLabel = pullRequest.state.uppercased()
    let draftLabel = pullRequest.isDraft ? "\(stateLabel)/DRAFT" : stateLabel
    let titlePrefix = Text("\(draftLabel) - ").foregroundStyle(.secondary)
    let titleSuffix = Text(verbatim: " #\(pullRequest.number)")
      .foregroundStyle(.secondary)
    let titleLine = Text("\(titlePrefix)\(pullRequest.title)\(titleSuffix)")
    let authorLogin = pullRequest.authorLogin ?? "Someone"
    let commitsCount = pullRequest.commitsCount ?? 0
    let commitsLabel = commitsCount == 1 ? "commit" : "commits"
    let baseRefName = pullRequest.baseRefName ?? "base"
    let headRefName = pullRequest.headRefName ?? "branch"
    let baseRef = Text("`\(baseRefName)`").monospaced()
    let headRef = Text("`\(headRefName)`").monospaced()
    let summaryLine = Text(
      "\(authorLogin) wants to merge \(commitsCount, format: .number) \(commitsLabel) into \(baseRef) from \(headRef)"
    ).foregroundStyle(.secondary)
    let additionsText = Text("+\(pullRequest.additions, format: .number)")
    let deletionsText = Text("-\(pullRequest.deletions, format: .number)")
    let hasConflicts = PullRequestMergeReadiness(pullRequest: pullRequest).isConflicting
    ScrollView {
      VStack(alignment: .leading) {
        if let pullRequestURL {
          Button {
            analyticsClient.capture("github_pr_opened", nil)
            openURL(pullRequestURL)
          } label: {
            titleLine
              .lineLimit(1)
          }
          .buttonStyle(.plain)
          .focusable(false)
          .help("Open pull request on GitHub (\(effectiveOpenPR?.display ?? "none"))")
          .appKeyboardShortcut(effectiveOpenPR)
          .font(.headline)
        } else {
          titleLine
            .lineLimit(1)
            .font(.headline)
        }
        summaryLine
          .font(.subheadline)
          .lineLimit(1)
        HStack {
          additionsText
            .foregroundStyle(.green)
          deletionsText
            .foregroundStyle(.red)
          if hasConflicts {
            Text("•")
              .foregroundStyle(.secondary)
            Text("Merge Conflicts")
              .foregroundStyle(.red)
          }
        }
        .font(.subheadline)

        if breakdown.total > 0 {
          HStack {
            PullRequestChecksRingView(breakdown: breakdown)
            Text(breakdown.summaryText)
              .foregroundStyle(.secondary)
          }
          .font(.caption)
        }

        if !sortedChecks.isEmpty {
          Divider()
          VStack(alignment: .leading) {
            ForEach(sortedChecks, id: \.self) { check in
              let style = PullRequestCheckStatusStyle(state: check.checkState)
              HStack {
                Image(systemName: style.symbol)
                  .foregroundStyle(style.color)
                  .accessibilityHidden(true)
                if let url = check.detailsUrl.flatMap(URL.init(string:)) {
                  Button {
                    analyticsClient.capture("github_ci_check_opened", nil)
                    openURL(url)
                  } label: {
                    Text(check.displayName)
                      .lineLimit(1)
                  }
                  .buttonStyle(.plain)
                  .focusable(false)
                  .help("Open check details on GitHub")
                } else {
                  Text(check.displayName)
                    .lineLimit(1)
                }
                Spacer()
                Text(style.label)
                  .foregroundStyle(.secondary)
              }
              .font(.caption)
            }
          }
        }
      }
      .padding()
    }
    .frame(minWidth: 260, maxWidth: 840, maxHeight: 720)
  }

  private static func sortRank(for state: GithubPullRequestCheckState) -> Int {
    switch state {
    case .failure:
      return 0
    case .inProgress:
      return 1
    case .expected:
      return 2
    case .skipped:
      return 3
    case .success:
      return 4
    }
  }

}
