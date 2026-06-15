import Foundation
import Testing

@testable import tty7

struct GitRemoteInfoTests {
  @Test func parseSSHRemote() {
    let info = GitClient.parseGithubRemoteInfo("git@github.com:octo/repo.git")
    #expect(info == GithubRemoteInfo(host: "github.com", owner: "octo", repo: "repo"))
  }

  @Test func parseSSHURLRemote() {
    let info = GitClient.parseGithubRemoteInfo("ssh://git@github.com/octo/repo.git")
    #expect(info == GithubRemoteInfo(host: "github.com", owner: "octo", repo: "repo"))
  }

  @Test func parseHTTPSRemote() {
    let info = GitClient.parseGithubRemoteInfo("https://github.com/octo/repo")
    #expect(info == GithubRemoteInfo(host: "github.com", owner: "octo", repo: "repo"))
  }

  @Test func parseEnterpriseRemote() {
    let info = GitClient.parseGithubRemoteInfo("git@github.acme.com:team/repo.git")
    #expect(info == GithubRemoteInfo(host: "github.acme.com", owner: "team", repo: "repo"))
  }

  @Test func rejectsNonGithubRemote() {
    let info = GitClient.parseGithubRemoteInfo("https://gitlab.com/group/repo.git")
    #expect(info == nil)
  }
}
