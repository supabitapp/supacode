import Foundation
import SupacodeSettingsShared
import Testing

@testable import supacode

struct GitHubDesktopOAuthTests {
  @Test func buildsAuthorizationURLForGithubCom() throws {
    let url = try #require(
      GitHubDesktopOAuth.authorizationURL(host: "github.com", state: "supacode-state")
    )

    #expect(
      url.absoluteString
        == "https://github.com/login/oauth/authorize?client_id=de0e3c7e9973e1c4dd77"
        + "&scope=repo%20user%20workflow&state=supacode-state"
    )
  }

  @Test func stateRoundTripsEnterpriseHost() throws {
    let state = GitHubDesktopOAuth.makeState(host: "https://ghe.example.test")

    #expect(GitHubDesktopOAuth.host(fromState: state) == "https://ghe.example.test")
  }

  @Test func normalizesDesktopAuthEndpointsLikeGitHubDesktop() throws {
    #expect(GitHubDesktopOAuth.endpoint(for: "github.com") == "https://api.github.com")
    #expect(GitHubDesktopOAuth.endpoint(for: "GitHub.com") == "https://api.github.com")
    #expect(GitHubDesktopOAuth.endpoint(for: "https://api.github.com") == "https://api.github.com")
    #expect(GitHubDesktopOAuth.endpoint(for: "ghe.example.test") == "https://ghe.example.test/api/v3")
    #expect(GitHubDesktopOAuth.endpoint(for: "https://octo.ghe.com") == "https://api.octo.ghe.com/")
    #expect(GitHubDesktopOAuth.endpoint(for: "http://ghe.example.test") == nil)
  }

  @Test func buildsAuthorizationURLForEnterpriseHTMLHost() throws {
    let url = try #require(
      GitHubDesktopOAuth.authorizationURL(host: "ghe.example.test", state: "supacode-state")
    )

    #expect(
      url.absoluteString
        == "https://ghe.example.test/login/oauth/authorize?client_id=de0e3c7e9973e1c4dd77"
        + "&scope=repo%20user%20workflow&state=supacode-state"
    )
  }

  @Test func buildsAuthenticatedEnterpriseAvatarRequest() throws {
    let account = GitHubDesktopAccount(
      endpoint: "https://ghe.example.test/api/v3",
      login: "work",
      name: "Work User",
      avatarURL: "https://ghe.example.test/avatars/u/3",
      id: 3,
      email: "work@example.test"
    )

    let request = try #require(GitHubDesktopOAuth.avatarRequest(for: account, token: "secret", size: 36))
    #expect(
      request.url?.absoluteString
        == "https://ghe.example.test/api/v3/enterprise/avatars/u/e?email=work@example.test&s=36"
    )
    #expect(request.value(forHTTPHeaderField: "Authorization") == "token secret")
  }
}
