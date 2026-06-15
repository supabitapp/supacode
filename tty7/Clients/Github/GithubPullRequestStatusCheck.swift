import Foundation

nonisolated struct GithubPullRequestStatusCheck: Decodable, Equatable, Hashable {
  let name: String?
  let detailsUrl: String?
  let status: String?
  let conclusion: String?
  let state: String?

  init(
    name: String? = nil,
    detailsUrl: String? = nil,
    status: String? = nil,
    conclusion: String? = nil,
    state: String? = nil
  ) {
    self.name = name
    self.detailsUrl = detailsUrl
    self.status = status
    self.conclusion = conclusion
    self.state = state
  }

  enum CodingKeys: String, CodingKey {
    case name
    case context
    case detailsUrl
    case targetUrl
    case status
    case conclusion
    case state
  }

  nonisolated init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let name = try container.decodeIfPresent(String.self, forKey: .name)
    let context = try container.decodeIfPresent(String.self, forKey: .context)
    self.name = name ?? context
    let detailsUrl = try container.decodeIfPresent(String.self, forKey: .detailsUrl)
    let targetUrl = try container.decodeIfPresent(String.self, forKey: .targetUrl)
    self.detailsUrl = detailsUrl ?? targetUrl
    self.status = try container.decodeIfPresent(String.self, forKey: .status)
    self.conclusion = try container.decodeIfPresent(String.self, forKey: .conclusion)
    self.state = try container.decodeIfPresent(String.self, forKey: .state)
  }

  var checkState: GithubPullRequestCheckState {
    if let status, status.uppercased() != "COMPLETED" {
      return .inProgress
    }
    if let state {
      switch state.uppercased() {
      case "SUCCESS":
        return .success
      case "FAILURE", "ERROR":
        return .failure
      case "EXPECTED":
        return .expected
      case "PENDING":
        return .inProgress
      default:
        return .inProgress
      }
    }
    if let conclusion {
      switch conclusion.uppercased() {
      case "SUCCESS", "NEUTRAL":
        return .success
      case "CANCELLED", "SKIPPED":
        return .skipped
      case "FAILURE", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE":
        return .failure
      default:
        return .inProgress
      }
    }
    return .inProgress
  }

  var displayName: String {
    name ?? "Check"
  }
}

nonisolated struct GithubPullRequestStatusCheckRollup: Decodable, Equatable, Hashable {
  let checks: [GithubPullRequestStatusCheck]

  init(checks: [GithubPullRequestStatusCheck]) {
    self.checks = checks
  }

  init(from decoder: Decoder) throws {
    if let checks = try? [GithubPullRequestStatusCheck](from: decoder) {
      self.checks = checks
      return
    }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let checks = try? container.decode([GithubPullRequestStatusCheck].self, forKey: .contexts) {
      self.checks = checks
      return
    }
    if let contexts = try? container.decode(GithubPullRequestStatusCheckContexts.self, forKey: .contexts) {
      self.checks = contexts.nodes
      return
    }
    self.checks = []
  }

  private enum CodingKeys: String, CodingKey {
    case contexts
  }
}

nonisolated private struct GithubPullRequestStatusCheckContexts: Decodable, Equatable {
  let nodes: [GithubPullRequestStatusCheck]
}

nonisolated struct PullRequestCheckBreakdown: Equatable {
  let passed: Int
  let failed: Int
  let inProgress: Int
  let expected: Int
  let skipped: Int

  var total: Int {
    passed + failed + inProgress + expected + skipped
  }

  var summaryText: String {
    var parts: [String] = []
    if failed > 0 {
      parts.append("\(failed) failed")
    }
    if inProgress > 0 {
      parts.append("\(inProgress) in progress")
    }
    if skipped > 0 {
      parts.append("\(skipped) skipped")
    }
    if expected > 0 {
      parts.append("\(expected) expected")
    }
    if total > 0 {
      parts.append("\(passed) successful")
    }
    if parts.isEmpty {
      return ""
    }
    return parts.joined(separator: ", ")
  }

  init(checks: [GithubPullRequestStatusCheck]) {
    var passed = 0
    var failed = 0
    var inProgress = 0
    var expected = 0
    var skipped = 0
    for check in checks {
      switch check.checkState {
      case .success:
        passed += 1
      case .failure:
        failed += 1
      case .inProgress:
        inProgress += 1
      case .expected:
        expected += 1
      case .skipped:
        skipped += 1
      }
    }
    self.passed = passed
    self.failed = failed
    self.inProgress = inProgress
    self.expected = expected
    self.skipped = skipped
  }
}
