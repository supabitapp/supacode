import CustomDump
import Foundation
import SupacodeSettingsFeature
import SupacodeSettingsShared

extension Repository: CustomDumpRepresentable {
  var customDumpValue: Any {
    (
      name: name,
      worktrees: worktrees.count
    )
  }
}

extension Worktree: CustomDumpRepresentable {
  var customDumpValue: Any {
    (
      id: id,
      name: name,
      detail: detail
    )
  }
}

extension RepositoriesFeature.State: CustomDumpRepresentable {
  var customDumpValue: Any {
    (
      repositories: repositories.count,
      selection: selection,
      pending: pendingWorktrees.count,
      deleting: sidebarItems.lazy.filter { $0.lifecycle == .deleting }.count,
      hasAlert: alert != nil
    )
  }
}

extension SettingsFeature.State: @retroactive CustomDumpRepresentable {
  public var customDumpValue: Any {
    (
      selection: selection,
      hasRepoSettings: repositorySettings != nil
    )
  }
}

extension AppFeature.State: CustomDumpRepresentable {
  var customDumpValue: Any {
    (
      openAction: openActionSelection,
      notificationCount: notificationIndicatorCount,
      hasAlert: alert != nil
    )
  }
}

extension RepositorySettingsFeature.State: @retroactive CustomDumpRepresentable {
  public var customDumpValue: Any {
    (
      rootURL: rootURL.lastPathComponent,
      isBare: isBareRepository,
      branchOptions: branchOptions.count
    )
  }
}

extension GithubPullRequest: CustomDumpRepresentable {
  var customDumpValue: Any {
    (
      number: number,
      state: state,
      isDraft: isDraft,
      reviewDecision: reviewDecision
    )
  }
}

extension GithubPullRequestStatusCheckRollup: CustomDumpRepresentable {
  var customDumpValue: Any {
    checks.count
  }
}

extension GitLabMergeRequest: CustomDumpRepresentable {
  var customDumpValue: Any {
    (
      iid: iid,
      state: state,
      isDraft: isDraft,
      pipelineStatus: pipelineStatus as Any
    )
  }
}

extension ForgePullRequest: CustomDumpRepresentable {
  var customDumpValue: Any {
    switch self {
    case .github(let pr): return ("github", pr.customDumpValue)
    case .gitlab(let mr): return ("gitlab", mr.customDumpValue)
    }
  }
}
