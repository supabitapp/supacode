import Foundation
import Testing

@testable import supacode

struct GitRemoteInfoTests {
  @Test func parseGithubSSHRemote() {
    let info = GitClient.parseRemoteInfo("git@github.com:octo/repo.git")
    #expect(info == ForgeRemoteInfo(forge: .github, host: "github.com", owner: "octo", repo: "repo"))
  }

  @Test func parseGithubSSHURLRemote() {
    let info = GitClient.parseRemoteInfo("ssh://git@github.com/octo/repo.git")
    #expect(info == ForgeRemoteInfo(forge: .github, host: "github.com", owner: "octo", repo: "repo"))
  }

  @Test func parseGithubHTTPSRemote() {
    let info = GitClient.parseRemoteInfo("https://github.com/octo/repo")
    #expect(info == ForgeRemoteInfo(forge: .github, host: "github.com", owner: "octo", repo: "repo"))
  }

  @Test func parseGithubEnterpriseRemote() {
    let info = GitClient.parseRemoteInfo("git@github.acme.com:team/repo.git")
    #expect(info == ForgeRemoteInfo(forge: .github, host: "github.acme.com", owner: "team", repo: "repo"))
  }

  @Test func parseGitlabHTTPSRemote() {
    let info = GitClient.parseRemoteInfo("https://gitlab.com/group/repo.git")
    #expect(info == ForgeRemoteInfo(forge: .gitlab, host: "gitlab.com", owner: "group", repo: "repo"))
  }

  @Test func parseGitlabSSHRemote() {
    let info = GitClient.parseRemoteInfo("git@gitlab.com:group/repo.git")
    #expect(info == ForgeRemoteInfo(forge: .gitlab, host: "gitlab.com", owner: "group", repo: "repo"))
  }

  @Test func parseGitlabSubgroupRemote() {
    let info = GitClient.parseRemoteInfo("git@gitlab.com:group/subgroup/project.git")
    #expect(
      info == ForgeRemoteInfo(forge: .gitlab, host: "gitlab.com", owner: "group/subgroup", repo: "project")
    )
  }

  @Test func parseGitlabSelfHostedRemote() {
    let info = GitClient.parseRemoteInfo("https://gitlab.acme.com/team/proj")
    #expect(info == ForgeRemoteInfo(forge: .gitlab, host: "gitlab.acme.com", owner: "team", repo: "proj"))
  }

  @Test func rejectsUnknownForgeRemote() {
    let info = GitClient.parseRemoteInfo("https://bitbucket.org/team/repo.git")
    #expect(info == nil)
  }
}
