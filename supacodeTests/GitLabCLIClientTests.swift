import ConcurrencyExtras
import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

private nonisolated let mergeRequestListJSON = """
  [
    {
      "iid": 12,
      "title": "Add feature",
      "state": "opened",
      "draft": false,
      "web_url": "https://gitlab.com/group/sub/proj/-/merge_requests/12",
      "source_branch": "feature",
      "target_branch": "main",
      "updated_at": "2026-08-01T10:00:00.000Z",
      "merged_at": null,
      "author": {"username": "dev"}
    },
    {
      "iid": 9,
      "title": "Old feature",
      "state": "merged",
      "draft": false,
      "web_url": "https://gitlab.com/group/sub/proj/-/merge_requests/9",
      "source_branch": "feature",
      "target_branch": "main",
      "updated_at": "2026-07-01T10:00:00Z",
      "merged_at": "2026-07-02T09:30:00.000Z",
      "author": {"username": "dev"}
    },
    {
      "iid": 11,
      "title": "Shipped",
      "state": "merged",
      "draft": false,
      "web_url": "https://gitlab.com/group/sub/proj/-/merge_requests/11",
      "source_branch": "shipped",
      "target_branch": "main",
      "updated_at": "2026-07-20T10:00:00.000Z",
      "merged_at": "2026-07-21T09:30:00.000Z",
      "author": {"username": "dev"}
    }
  ]
  """

struct GitLabCLIClientTests {
  private static func glabShell(stdout: String, onLogin: (@Sendable ([String]) -> Void)? = nil) -> ShellClient {
    ShellClient(
      run: { executableURL, _, _ in
        if executableURL.lastPathComponent == "which" {
          return ShellOutput(stdout: "/usr/local/bin/glab", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { executableURL, arguments, _, _ in
        guard executableURL.lastPathComponent == "glab" else {
          return ShellOutput(stdout: "", stderr: "", exitCode: 0)
        }
        onLogin?(arguments)
        return ShellOutput(stdout: stdout, stderr: "", exitCode: 0)
      }
    )
  }

  @Test func fetchMergeRequestsMatchesBranchesAndPrefersOpenState() async throws {
    let client = GitLabCLIClient.live(shell: Self.glabShell(stdout: mergeRequestListJSON))

    let results = try await client.fetchMergeRequests(
      "gitlab.com", "group/sub/proj", ["feature", "shipped", "absent"]
    )

    // Two MRs share the `feature` source branch; the open one wins.
    #expect(results["feature"]?.number == 12)
    #expect(results["feature"]?.state == .open)
    #expect(results["feature"]?.headRefName == "feature")
    #expect(results["feature"]?.baseRefName == "main")
    #expect(results["feature"]?.authorLogin == "dev")
    #expect(results["feature"]?.additions == nil)
    #expect(results["feature"]?.statusCheckRollup == nil)
    // Merged proposals must surface (state-inclusive sweep), with mergedAt.
    #expect(results["shipped"]?.state == .merged)
    #expect(results["shipped"]?.mergedAt != nil)
    #expect(results["absent"] == nil)
  }

  @Test func fetchMergeRequestsQueriesHostExplicitlyWithStateAll() async throws {
    let recorded = LockIsolated<[[String]]>([])
    let client = GitLabCLIClient.live(
      shell: Self.glabShell(stdout: mergeRequestListJSON) { arguments in
        recorded.withValue { $0.append(arguments) }
      }
    )

    _ = try await client.fetchMergeRequests("git.acme.com", "group/proj", ["feature"])

    let arguments = try #require(recorded.value.first)
    #expect(arguments.contains("--hostname"))
    #expect(arguments.contains("git.acme.com"))
    let endpoint = try #require(arguments.last)
    #expect(endpoint.contains("projects/group%2Fproj/merge_requests"))
    #expect(endpoint.contains("state=all"))
    #expect(endpoint.contains("order_by=updated_at"))
  }

  @Test func mergePassesExplicitAutoMergeAndSquash() async throws {
    let recorded = LockIsolated<[[String]]>([])
    let client = GitLabCLIClient.live(
      shell: Self.glabShell(stdout: "") { arguments in
        recorded.withValue { $0.append(arguments) }
      }
    )

    try await client.mergeMergeRequest(
      URL(fileURLWithPath: "/tmp/repo"), "gitlab.com", "group/proj", 12, .squash
    )

    let arguments = try #require(recorded.value.first)
    #expect(arguments.contains("merge"))
    #expect(arguments.contains("--auto-merge=false"))
    #expect(arguments.contains("--squash"))
    #expect(arguments.contains("https://gitlab.com/group/proj"))
  }

  @Test func mergeRejectsRebaseAsUnsupported() async {
    let client = GitLabCLIClient.live(shell: Self.glabShell(stdout: ""))

    do {
      try await client.mergeMergeRequest(
        URL(fileURLWithPath: "/tmp/repo"), "gitlab.com", "group/proj", 12, .rebase
      )
      Issue.record("Expected an unsupported error")
    } catch let error as ForgeClientError {
      #expect(error == .unsupported(operation: "rebase merges"))
    } catch {
      Issue.record("Unexpected error type: \(error.localizedDescription)")
    }
  }

  @Test func configHostsParseHostEntries() {
    let configYAML = """
      git_protocol: ssh
      hosts:
        gitlab.com:
          token: abc
          user: dev
        git.acme.com:
          token: def
      check_update: true
      """
    #expect(GitLabConfigHosts.parse(configYAML: configYAML) == ["gitlab.com", "git.acme.com"])
  }

  @Test func configHostsIgnoreNestedKeysAndMissingSection() {
    #expect(GitLabConfigHosts.parse(configYAML: "git_protocol: ssh\n") == [])
    let nested = """
      hosts:
        gitlab.com:
          api_host:
            value: nope
      """
    #expect(GitLabConfigHosts.parse(configYAML: nested) == ["gitlab.com"])
  }
}

struct GitLabMergeStatusMappingTests {
  private func readiness(
    detailedMergeStatus: String?,
    hasConflicts: Bool? = nil,
    pipelineStatus: String? = nil
  ) -> PullRequestMergeReadiness {
    let detail = GitLabMergeRequestDetail(
      iid: 12,
      detailedMergeStatus: detailedMergeStatus,
      hasConflicts: hasConflicts,
      headPipeline: pipelineStatus.map {
        GitLabMergeRequestDetail.Pipeline(id: 7, status: $0, webUrl: "https://gitlab.com/p/1")
      }
    )
    let summary = ForgePullRequest(
      number: 12,
      title: "MR",
      state: .open,
      additions: nil,
      deletions: nil,
      isDraft: false,
      reviewDecision: nil,
      mergeable: nil,
      mergeStateStatus: nil,
      updatedAt: nil,
      mergedAt: nil,
      url: "https://gitlab.com/group/proj/-/merge_requests/12",
      headRefName: "feature",
      baseRefName: "main",
      commitsCount: nil,
      authorLogin: "dev",
      statusCheckRollup: nil,
      mergeQueueEntry: nil
    )
    return PullRequestMergeReadiness(pullRequest: summary.applying(detail.pullRequestDetail))
  }

  @Test func mergeableResolvesToMergeable() {
    #expect(readiness(detailedMergeStatus: "mergeable").canMergeNow)
  }

  @Test func conflictResolvesToMergeConflicts() {
    #expect(readiness(detailedMergeStatus: "conflict").assessment == .blocked(.mergeConflicts))
    let conflicted = readiness(detailedMergeStatus: "cannot_be_merged", hasConflicts: true)
    #expect(conflicted.assessment == .blocked(.mergeConflicts))
  }

  @Test func requestedChangesResolvesToChangesRequested() {
    #expect(readiness(detailedMergeStatus: "requested_changes").assessment == .blocked(.changesRequested))
  }

  @Test func blockingStatusesCarryForgeProse() {
    #expect(readiness(detailedMergeStatus: "not_approved").assessment == .blocked(.other("Not approved")))
    #expect(readiness(detailedMergeStatus: "ci_must_pass").assessment == .blocked(.other("Pipeline must succeed")))
    #expect(readiness(detailedMergeStatus: "not_approved").label == "Not approved")
  }

  @Test func pendingAndUnknownStatusesResolveToChecking() {
    // In-flight statuses must read as pending, never as a red block.
    for status in ["checking", "unchecked", "ci_still_running", "approvals_syncing", "some_future_status"] {
      #expect(readiness(detailedMergeStatus: status).assessment == .checking, "\(status)")
    }
  }

  @Test func failedPipelineBlocksThroughTheSharedChecksLadder() {
    let readiness = readiness(detailedMergeStatus: "ci_must_pass", pipelineStatus: "failed")
    #expect(readiness.assessment == .blocked(.checksFailed(1)))
  }

  @Test func pipelineMapsToASingleRollupCheck() {
    let detail = GitLabMergeRequestDetail(
      iid: 12,
      detailedMergeStatus: "mergeable",
      hasConflicts: false,
      headPipeline: GitLabMergeRequestDetail.Pipeline(id: 7, status: "running", webUrl: "https://gitlab.com/p/1")
    ).pullRequestDetail
    let checks = detail.statusCheckRollup?.checks ?? []
    #expect(checks.count == 1)
    #expect(checks.first?.checkState == .inProgress)
    #expect(checks.first?.displayName == "Pipeline")
    #expect(detail.forgeBlockedReason == nil)
  }
}
