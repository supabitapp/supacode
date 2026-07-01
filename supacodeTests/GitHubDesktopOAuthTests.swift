import Foundation
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
}
