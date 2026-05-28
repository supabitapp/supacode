import Foundation
import Testing

@testable import supacode

struct GitLabAuthStatusParsingTests {
  @Test func parsesGitlabComLoggedInLine() {
    let output = """
      gitlab.com
        ✓ Logged in to gitlab.com as octouser (api)
        ✓ Token: ***
      """
    let status = parseGlabAuthStatus(output)
    #expect(status == GitLabAuthStatus(username: "octouser", host: "gitlab.com"))
  }

  @Test func parsesSelfHostedLoggedInLine() {
    let output = "✓ Logged in to gitlab.acme.com as team-bot (api, write_repository)"
    let status = parseGlabAuthStatus(output)
    #expect(status == GitLabAuthStatus(username: "team-bot", host: "gitlab.acme.com"))
  }

  @Test func returnsNilWhenNotAuthenticated() {
    let output = "No tokens configured. Run `glab auth login` to get started."
    let status = parseGlabAuthStatus(output)
    #expect(status == nil)
  }
}

struct GitLabMergeRequestResponseTests {
  private func decodePayload(_ json: String) throws -> GitLabGraphQLMergeRequestResponse {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(GitLabGraphQLMergeRequestResponse.self, from: Data(json.utf8))
  }

  @Test func decodesOpenMergeRequestKeyedBySourceBranch() throws {
    let json = """
      {
        "data": {
          "project": {
            "mergeRequests": {
              "nodes": [
                {
                  "iid": "42",
                  "title": "Add login flow",
                  "state": "opened",
                  "draft": false,
                  "webUrl": "https://gitlab.com/g/p/-/merge_requests/42",
                  "updatedAt": "2026-05-27T10:00:00Z",
                  "sourceBranch": "feature/login",
                  "targetBranch": "main",
                  "diffStatsSummary": { "additions": 12, "deletions": 3 },
                  "author": { "username": "octouser" },
                  "headPipeline": { "status": "RUNNING" }
                }
              ]
            }
          }
        }
      }
      """
    let response = try decodePayload(json)
    let byBranch = response.mergeRequestsBySourceBranch()
    let mr = try #require(byBranch["feature/login"])
    #expect(mr.iid == 42)
    #expect(mr.title == "Add login flow")
    #expect(mr.state == .opened)
    #expect(mr.isDraft == false)
    #expect(mr.additions == 12)
    #expect(mr.deletions == 3)
    #expect(mr.authorUsername == "octouser")
    #expect(mr.pipelineStatus == .running)
    #expect(mr.url == "https://gitlab.com/g/p/-/merge_requests/42")
    #expect(mr.targetBranch == "main")
  }

  @Test func dropsNodesWithoutSourceBranch() throws {
    let json = """
      {
        "data": {
          "project": {
            "mergeRequests": {
              "nodes": [
                {
                  "iid": "1",
                  "title": "Detached",
                  "state": "opened",
                  "webUrl": "https://gitlab.com/g/p/-/merge_requests/1",
                  "sourceBranch": null,
                  "targetBranch": "main"
                }
              ]
            }
          }
        }
      }
      """
    let response = try decodePayload(json)
    #expect(response.mergeRequestsBySourceBranch().isEmpty)
  }

  @Test func handlesMissingProject() throws {
    let json = #"{"data":{"project":null}}"#
    let response = try decodePayload(json)
    #expect(response.mergeRequestsBySourceBranch().isEmpty)
  }

  @Test func keepsMostRecentlyUpdatedOnBranchCollision() throws {
    let json = """
      {
        "data": {
          "project": {
            "mergeRequests": {
              "nodes": [
                {
                  "iid": "1",
                  "title": "Older",
                  "state": "opened",
                  "webUrl": "https://gitlab.com/g/p/-/merge_requests/1",
                  "updatedAt": "2026-05-20T10:00:00Z",
                  "sourceBranch": "feature/x",
                  "targetBranch": "main"
                },
                {
                  "iid": "2",
                  "title": "Newer",
                  "state": "opened",
                  "webUrl": "https://gitlab.com/g/p/-/merge_requests/2",
                  "updatedAt": "2026-05-27T10:00:00Z",
                  "sourceBranch": "feature/x",
                  "targetBranch": "main"
                }
              ]
            }
          }
        }
      }
      """
    let response = try decodePayload(json)
    let mr = try #require(response.mergeRequestsBySourceBranch()["feature/x"])
    #expect(mr.iid == 2)
    #expect(mr.title == "Newer")
  }
}

struct GitLabPipelineStatusTests {
  @Test func mapsKnownStates() {
    #expect(GitLabPipelineStatus(rawGraphQL: "RUNNING") == .running)
    #expect(GitLabPipelineStatus(rawGraphQL: "success") == .success)
    #expect(GitLabPipelineStatus(rawGraphQL: "FAILED") == .failed)
    #expect(GitLabPipelineStatus(rawGraphQL: "CANCELLED") == .canceled)
    #expect(GitLabPipelineStatus(rawGraphQL: "canceled") == .canceled)
    #expect(GitLabPipelineStatus(rawGraphQL: "WAITING_FOR_RESOURCE") == .waitingForResource)
  }

  @Test func unknownStateFallsThrough() {
    #expect(GitLabPipelineStatus(rawGraphQL: "totally-new-state") == .unknown)
  }

  @Test func inProgressCoversPendingAndRunning() {
    #expect(GitLabPipelineStatus.running.isInProgress)
    #expect(GitLabPipelineStatus.pending.isInProgress)
    #expect(GitLabPipelineStatus.scheduled.isInProgress)
    #expect(!GitLabPipelineStatus.success.isInProgress)
    #expect(!GitLabPipelineStatus.failed.isInProgress)
  }
}

struct ForgeDetectionTests {
  @Test func detectsGithubHost() {
    #expect(Forge.detect(host: "github.com") == .github)
    #expect(Forge.detect(host: "github.acme.com") == .github)
  }

  @Test func detectsGitlabHost() {
    #expect(Forge.detect(host: "gitlab.com") == .gitlab)
    #expect(Forge.detect(host: "gitlab.acme.com") == .gitlab)
  }

  @Test func returnsNilForUnknown() {
    #expect(Forge.detect(host: "bitbucket.org") == nil)
  }
}
