import Foundation
import Testing

@testable import supacode

struct GithubBatchPullRequestsTests {
  @Test func mapsGraphQLAliasesToBranches() throws {
    let json = """
      {
        "data": {
          "repository": {
            "branch0": {
              "nodes": [
                {
                  "number": 1,
                  "title": "Fork PR",
                  "state": "OPEN",
                  "additions": 1,
                  "deletions": 0,
                  "isDraft": false,
                  "reviewDecision": null,
                  "updatedAt": "2025-01-03T00:00:00Z",
                  "url": "https://github.com/other/repo/pull/1",
                  "headRefName": "feature-a",
                  "headRepository": {
                    "name": "repo",
                    "owner": { "login": "other" }
                  }
                },
                {
                  "number": 2,
                  "title": "Primary PR",
                  "state": "OPEN",
                  "additions": 2,
                  "deletions": 1,
                  "isDraft": false,
                  "reviewDecision": "APPROVED",
                  "updatedAt": "2025-01-02T00:00:00Z",
                  "url": "https://github.com/octo/repo/pull/2",
                  "headRefName": "feature-a",
                  "headRepository": {
                    "name": "repo",
                    "owner": { "login": "octo" }
                  }
                }
              ]
            },
            "branch1": {
              "nodes": []
            }
          }
        }
      }
      """
    let data = Data(json.utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let response = try decoder.decode(GithubGraphQLPullRequestResponse.self, from: data)
    let prs = response.pullRequestsByBranch(
      aliasMap: ["branch0": "feature-a", "branch1": "feature-b"],
      owner: "octo",
      repo: "repo"
    )
    #expect(prs["feature-a"]?.number == 2)
    #expect(prs["feature-a"]?.title == "Primary PR")
    #expect(prs["feature-b"] == nil)
  }

  @Test func ignoresForkPRWhenBaseRefMatchesBranch() throws {
    // Fork PR "fork:main → main" should be filtered out for local
    // "main" because the local branch is the PR's target, not its source.
    let json = """
      {
        "data": {
          "repository": {
            "branch0": {
              "nodes": [
                {
                  "number": 9,
                  "title": "Fork PR",
                  "state": "MERGED",
                  "additions": 1,
                  "deletions": 0,
                  "isDraft": false,
                  "reviewDecision": null,
                  "updatedAt": "2025-01-01T00:00:00Z",
                  "url": "https://github.com/fork/repo/pull/9",
                  "headRefName": "main",
                  "baseRefName": "main",
                  "headRepository": {
                    "name": "repo",
                    "owner": { "login": "fork" }
                  }
                }
              ]
            }
          }
        }
      }
      """
    let data = Data(json.utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let response = try decoder.decode(GithubGraphQLPullRequestResponse.self, from: data)
    let prs = response.pullRequestsByBranch(
      aliasMap: ["branch0": "main"],
      owner: "octo",
      repo: "repo"
    )
    #expect(prs["main"] == nil)
  }

  @Test func matchesForkPRWhenBaseRefDiffersFromBranch() throws {
    // Fork PR "fork:feature-a → main" should be selected for local
    // "feature-a" because the local branch is the PR's source, not its target.
    let json = """
      {
        "data": {
          "repository": {
            "branch0": {
              "nodes": [
                {
                  "number": 9,
                  "title": "Fork PR",
                  "state": "OPEN",
                  "additions": 1,
                  "deletions": 0,
                  "isDraft": false,
                  "reviewDecision": null,
                  "updatedAt": "2025-01-01T00:00:00Z",
                  "url": "https://github.com/fork/repo/pull/9",
                  "headRefName": "feature-a",
                  "baseRefName": "main",
                  "headRepository": {
                    "name": "repo",
                    "owner": { "login": "fork" }
                  }
                }
              ]
            }
          }
        }
      }
      """
    let data = Data(json.utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let response = try decoder.decode(GithubGraphQLPullRequestResponse.self, from: data)
    let prs = response.pullRequestsByBranch(
      aliasMap: ["branch0": "feature-a"],
      owner: "octo",
      repo: "repo"
    )
    #expect(prs["feature-a"]?.number == 9)
    #expect(prs["feature-a"]?.title == "Fork PR")
  }

  @Test func skipsNilHeadRepositoryInForkFallback() throws {
    // When falling back to fork PRs, nodes with nil headRepository
    // are excluded. The fork PR with a valid headRepository wins.
    let json = """
      {
        "data": {
          "repository": {
            "branch0": {
              "nodes": [
                {
                  "number": 7,
                  "title": "Head Missing",
                  "state": "OPEN",
                  "additions": 1,
                  "deletions": 0,
                  "isDraft": false,
                  "reviewDecision": null,
                  "updatedAt": "2025-01-02T00:00:00Z",
                  "url": "https://github.com/octo/repo/pull/7",
                  "headRefName": "feature-a",
                  "baseRefName": "main",
                  "headRepository": null
                },
                {
                  "number": 8,
                  "title": "Fork PR",
                  "state": "OPEN",
                  "additions": 1,
                  "deletions": 0,
                  "isDraft": false,
                  "reviewDecision": null,
                  "updatedAt": "2025-01-01T00:00:00Z",
                  "url": "https://github.com/fork/repo/pull/8",
                  "headRefName": "feature-a",
                  "baseRefName": "main",
                  "headRepository": {
                    "name": "repo",
                    "owner": { "login": "fork" }
                  }
                }
              ]
            }
          }
        }
      }
      """
    let data = Data(json.utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let response = try decoder.decode(GithubGraphQLPullRequestResponse.self, from: data)
    let prs = response.pullRequestsByBranch(
      aliasMap: ["branch0": "feature-a"],
      owner: "octo",
      repo: "repo"
    )
    #expect(prs["feature-a"]?.number == 8)
  }

  @Test func prefersOpenOverMergedEvenIfOlder() throws {
    let json = """
      {
        "data": {
          "repository": {
            "branch0": {
              "nodes": [
                {
                  "number": 10,
                  "title": "Merged PR",
                  "state": "MERGED",
                  "additions": 1,
                  "deletions": 0,
                  "isDraft": false,
                  "reviewDecision": null,
                  "updatedAt": "2026-01-02T00:00:00Z",
                  "url": "https://github.com/octo/repo/pull/10",
                  "headRefName": "feature-a",
                  "headRepository": {
                    "name": "repo",
                    "owner": { "login": "octo" }
                  }
                },
                {
                  "number": 11,
                  "title": "Open PR",
                  "state": "OPEN",
                  "additions": 2,
                  "deletions": 1,
                  "isDraft": false,
                  "reviewDecision": null,
                  "updatedAt": "2026-01-01T00:00:00Z",
                  "url": "https://github.com/octo/repo/pull/11",
                  "headRefName": "feature-a",
                  "headRepository": {
                    "name": "repo",
                    "owner": { "login": "octo" }
                  }
                }
              ]
            }
          }
        }
      }
      """
    let data = Data(json.utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let response = try decoder.decode(GithubGraphQLPullRequestResponse.self, from: data)
    let prs = response.pullRequestsByBranch(
      aliasMap: ["branch0": "feature-a"],
      owner: "octo",
      repo: "repo"
    )
    #expect(prs["feature-a"]?.number == 11)
    #expect(prs["feature-a"]?.title == "Open PR")
  }

  @Test func fallsBackToLatestMerged() throws {
    let json = """
      {
        "data": {
          "repository": {
            "branch0": {
              "nodes": [
                {
                  "number": 20,
                  "title": "Merged Older",
                  "state": "MERGED",
                  "additions": 1,
                  "deletions": 0,
                  "isDraft": false,
                  "reviewDecision": null,
                  "updatedAt": "2026-01-01T00:00:00Z",
                  "url": "https://github.com/octo/repo/pull/20",
                  "headRefName": "feature-a",
                  "headRepository": {
                    "name": "repo",
                    "owner": { "login": "octo" }
                  }
                },
                {
                  "number": 21,
                  "title": "Merged Newer",
                  "state": "MERGED",
                  "additions": 2,
                  "deletions": 1,
                  "isDraft": false,
                  "reviewDecision": null,
                  "updatedAt": "2026-01-03T00:00:00Z",
                  "url": "https://github.com/octo/repo/pull/21",
                  "headRefName": "feature-a",
                  "headRepository": {
                    "name": "repo",
                    "owner": { "login": "octo" }
                  }
                }
              ]
            }
          }
        }
      }
      """
    let data = Data(json.utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let response = try decoder.decode(GithubGraphQLPullRequestResponse.self, from: data)
    let prs = response.pullRequestsByBranch(
      aliasMap: ["branch0": "feature-a"],
      owner: "octo",
      repo: "repo"
    )
    #expect(prs["feature-a"]?.number == 21)
    #expect(prs["feature-a"]?.title == "Merged Newer")
  }

  @Test func excludesForkPRWithNilBaseRefName() throws {
    // When baseRefName is nil the filter cannot determine whether the
    // local branch is the PR's target, so the PR is excluded conservatively.
    let json = """
      {
        "data": {
          "repository": {
            "branch0": {
              "nodes": [
                {
                  "number": 30,
                  "title": "Fork Missing Base",
                  "state": "OPEN",
                  "additions": 1,
                  "deletions": 0,
                  "isDraft": false,
                  "reviewDecision": null,
                  "updatedAt": "2025-01-01T00:00:00Z",
                  "url": "https://github.com/fork/repo/pull/30",
                  "headRefName": "main",
                  "headRepository": {
                    "name": "repo",
                    "owner": { "login": "fork" }
                  }
                }
              ]
            }
          }
        }
      }
      """
    let data = Data(json.utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let response = try decoder.decode(GithubGraphQLPullRequestResponse.self, from: data)
    let prs = response.pullRequestsByBranch(
      aliasMap: ["branch0": "main"],
      owner: "octo",
      repo: "repo"
    )
    #expect(prs["main"] == nil)
  }
}
