import Foundation
import Testing

@testable import supacode

struct GitHubDesktopDeeplinkParserTests {
  @Test func parsesOpenRepoAsGithubDesktopClone() {
    let url = URL(string: "x-github-client://openRepo/https://github.com/supabitapp/supacode")!

    let deeplink = DeeplinkClient.liveValue.parse(url)

    #expect(deeplink == .githubDesktopClone(repositoryURL: URL(string: "https://github.com/supabitapp/supacode")!))
  }

  @Test func parsesCloneRepoAsGithubDesktopClone() {
    let url = URL(string: "x-github-client://cloneRepo/https://github.com/supabitapp/supacode")!

    let deeplink = DeeplinkClient.liveValue.parse(url)

    #expect(deeplink == .githubDesktopClone(repositoryURL: URL(string: "https://github.com/supabitapp/supacode")!))
  }

  @Test func parsesOpenRepoWithBranchQueryAsGithubDesktopClone() {
    let url = URL(string: "x-github-client://openRepo/https://github.com/balcsida/homebrew-tap?branch=main")!

    let deeplink = DeeplinkClient.liveValue.parse(url)

    #expect(deeplink == .githubDesktopClone(repositoryURL: URL(string: "https://github.com/balcsida/homebrew-tap")!))
  }

  @Test func parsesDesktopAuthCallback() {
    let url = URL(string: "x-github-desktop-auth://oauth?code=abc123&state=state-123")!
    let deeplink = DeeplinkClient.liveValue.parse(url)

    #expect(deeplink == .githubDesktopOAuth(code: "abc123", state: "state-123"))
  }

  @Test func parsesClientAuthCallback() {
    let url = URL(string: "x-github-client://oauth?code=abc123&state=state-123")!
    let deeplink = DeeplinkClient.liveValue.parse(url)

    #expect(deeplink == .githubDesktopOAuth(code: "abc123", state: "state-123"))
  }

  @Test func rejectsUnsupportedGithubDesktopAction() {
    let url = URL(string: "x-github-client://unknown/https://github.com/supabitapp/supacode")!

    #expect(DeeplinkClient.liveValue.parse(url) == nil)
  }

  @Test func rejectsNonHTTPSGithubDesktopRepositoryURL() {
    let url = URL(string: "x-github-client://cloneRepo/git@github.com:supabitapp/supacode.git")!

    #expect(DeeplinkClient.liveValue.parse(url) == nil)
  }

  @Test func rejectsGithubDesktopRepositoryURLWithQuery() {
    let url = URL(string: "x-github-client://cloneRepo/https://github.com/supabitapp/supacode?token=secret")!

    #expect(DeeplinkClient.liveValue.parse(url) == nil)
  }

  @Test func rejectsGithubDesktopRepositoryURLWithUnsafePath() {
    let url = URL(string: "x-github-client://cloneRepo/https://github.com/supabitapp/../supacode")!

    #expect(DeeplinkClient.liveValue.parse(url) == nil)
  }
}
