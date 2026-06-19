import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

struct RepositoryIdentityTests {
  // MARK: - Branded id codable shape

  @Test func repositoryIDEncodesAsBareString() throws {
    let id = RepositoryID("/Users/me/repo/")
    let data = try JSONEncoder().encode(id)
    #expect(String(bytes: data, encoding: .utf8) == "\"\\/Users\\/me\\/repo\\/\"")
    #expect(try JSONDecoder().decode(RepositoryID.self, from: data) == id)
  }

  @Test func worktreeIDEncodesAsBareString() throws {
    let id = WorktreeID("folder:/Users/me/repo/")
    let data = try JSONEncoder().encode(id)
    #expect(try JSONDecoder().decode(WorktreeID.self, from: data) == id)
  }

  @Test func stringLiteralBridges() {
    let repo: RepositoryID = "/tmp/x/"
    let worktree: WorktreeID = "/tmp/x/wt"
    #expect(repo.rawValue == "/tmp/x/")
    #expect(worktree.rawValue == "/tmp/x/wt")
  }

  // MARK: - RemoteHost.authority

  @Test func authorityFoldsInUserAndPort() {
    #expect(RemoteHost(alias: "box").authority == "box")
    #expect(RemoteHost(alias: "box", username: "me").authority == "me@box")
    #expect(RemoteHost(alias: "box", username: "me", port: 2222).authority == "me@box:2222")
    #expect(RemoteHost(alias: "box", port: 2222).authority == "box:2222")
  }

  @Test func displayAuthorityDropsDefaultPortAndUnsetUser() {
    #expect(RemoteHost(alias: "box").displayAuthority == "box")
    #expect(RemoteHost(alias: "box", username: "me").displayAuthority == "me@box")
    // Default port 22 is dropped (unlike `authority`); a non-default port shows.
    #expect(RemoteHost(alias: "box", port: 22).displayAuthority == "box")
    #expect(RemoteHost(alias: "box", port: 2222).displayAuthority == "box:2222")
    #expect(RemoteHost(alias: "box", username: "me", port: 2222).displayAuthority == "me@box:2222")
  }

  // MARK: - RepositoryLocation

  @Test func localLocationDerivesPathIDAndExposesLocalURL() {
    let url = URL(fileURLWithPath: "/Users/me/repo", isDirectory: true)
    let location = RepositoryLocation.local(url)
    #expect(location.host == nil)
    #expect(location.localRootURL == url)
    #expect(location.id == RepositoryID("/Users/me/repo/"))
  }

  @Test func remoteLocationBrandsHostAndHidesLocalURL() {
    let host = RemoteHost(alias: "box", username: "me", port: 2222)
    let location = RepositoryLocation.remote(host, path: "/srv/repo")
    #expect(location.host == host)
    // The danger this whole refactor removes: a remote location yields no local URL.
    #expect(location.localRootURL == nil)
    #expect(location.id == RepositoryID("remote://me@box:2222/srv/repo"))
    #expect(location.path == "/srv/repo")
  }

  @Test func remoteWithoutPortOmitsPort() {
    let host = RemoteHost(alias: "box")
    #expect(RepositoryLocation.remote(host, path: "/srv/repo").id == RepositoryID("remote://box/srv/repo"))
  }

  // MARK: - WorktreeLocation id derivation

  @Test func localGitWorktreeIDIsBarePath() {
    let location = WorktreeLocation.local(
      workingDirectory: URL(fileURLWithPath: "/repo/wt"),
      repositoryRoot: URL(fileURLWithPath: "/repo")
    )
    #expect(location.id(kind: .git) == WorktreeID("/repo/wt"))
    #expect(location.localWorkingDirectory == URL(fileURLWithPath: "/repo/wt"))
  }

  @Test func remoteGitWorktreeIDBrandsHost() {
    let host = RemoteHost(alias: "box", port: 22)
    let location = WorktreeLocation.remote(host, workingDirectory: "/repo/wt", repositoryRoot: "/repo")
    #expect(location.id(kind: .git) == WorktreeID("remote://box:22/repo/wt"))
    #expect(location.localWorkingDirectory == nil)
    #expect(location.host == host)
  }

  // MARK: - Folder synthetic round-trip

  @Test func localFolderWorktreeIDRoundTripsToRepositoryID() {
    let repoURL = URL(fileURLWithPath: "/Users/me/notes", isDirectory: true)
    let location = WorktreeLocation.local(workingDirectory: repoURL, repositoryRoot: repoURL)
    let id = location.id(kind: .folder)
    #expect(id == WorktreeID("folder:/Users/me/notes/"))
    #expect(id.isFolder)
    #expect(id.folderRepositoryID == RepositoryID("/Users/me/notes/"))
  }

  @Test func remoteFolderWorktreeIDRoundTripsToRemoteRepositoryID() {
    let host = RemoteHost(alias: "box", username: "me")
    let location = WorktreeLocation.remote(host, workingDirectory: "/srv/notes", repositoryRoot: "/srv/notes")
    let id = location.id(kind: .folder)
    #expect(id == WorktreeID("folder:remote://me@box/srv/notes"))
    #expect(id.isFolder)
    #expect(id.folderRepositoryID == RepositoryID("remote://me@box/srv/notes"))
  }

  @Test func gitWorktreeIDIsNotAFolder() {
    #expect(WorktreeID("/repo/wt").isFolder == false)
    #expect(WorktreeID("/repo/wt").folderRepositoryID == nil)
    #expect(WorktreeID("remote://box/repo/wt").folderRepositoryID == nil)
  }

  @Test func worktreeLocationExposesOwningRepositoryLocation() {
    let host = RemoteHost(alias: "box")
    let remote = WorktreeLocation.remote(host, workingDirectory: "/repo/wt", repositoryRoot: "/repo")
    #expect(remote.repositoryLocation.id == RepositoryID("remote://box/repo"))
    let local = WorktreeLocation.local(
      workingDirectory: URL(fileURLWithPath: "/repo/wt"),
      repositoryRoot: URL(fileURLWithPath: "/repo", isDirectory: true)
    )
    #expect(local.repositoryLocation.id == RepositoryID("/repo/"))
  }
}
