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
    let id = WorktreeID("/Users/me/repo/wt")
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
    #expect(location.id == RepositoryID("me@box:2222/srv/repo"))
    #expect(location.path == "/srv/repo")
  }

  @Test func remoteWithoutPortOmitsPort() {
    let host = RemoteHost(alias: "box")
    #expect(RepositoryLocation.remote(host, path: "/srv/repo").id == RepositoryID("box/srv/repo"))
  }

  // MARK: - RemoteHost authority round-trip

  @Test func authorityParsesBackToHost() {
    for host in [
      RemoteHost(alias: "box"),
      RemoteHost(alias: "box", username: "me"),
      RemoteHost(alias: "box", port: 2222),
      RemoteHost(alias: "box", username: "me", port: 2222),
      // IPv6 literals must round-trip too: `authority` brackets the host so the
      // `:port` (and the colons in the address) stay unambiguous.
      RemoteHost(alias: "fe80::1"),
      RemoteHost(alias: "fe80::1", port: 2222),
      RemoteHost(alias: "::1", username: "me", port: 22),
    ] {
      #expect(RemoteHost(authority: host.authority) == host)
    }
  }

  @Test func remoteIDRoundTripsForEveryHostShape() {
    for host in [
      RemoteHost(alias: "box"),
      RemoteHost(alias: "box", username: "me", port: 2222),
      RemoteHost(alias: "fe80::1"),
      RemoteHost(alias: "fe80::1", username: "me", port: 2222),
    ] {
      let location = RepositoryLocation.remote(host, path: "/srv/repo")
      #expect(RepositoryLocation.parse(persistedID: location.id.rawValue) == location)
    }
  }

  @Test func authorityParserHandlesBracketedIPv6() {
    let host = RemoteHost(authority: "me@[fe80::1]:2222")
    #expect(host == RemoteHost(alias: "fe80::1", username: "me", port: 2222))
  }

  @Test func authorityParserRejectsEmptyHost() {
    #expect(RemoteHost(authority: "") == nil)
    #expect(RemoteHost(authority: "me@") == nil)
  }

  // MARK: - RepositoryLocation persisted-id parsing

  @Test func parsesLocalAndRemotePersistedIDs() {
    #expect(RepositoryLocation.parse(persistedID: "/Users/me/repo") == .local(URL(fileURLWithPath: "/Users/me/repo")))
    #expect(
      RepositoryLocation.parse(persistedID: "me@box:2222/srv/repo")
        == .remote(RemoteHost(alias: "box", username: "me", port: 2222), path: "/srv/repo"))
    #expect(
      RepositoryLocation.parse(persistedID: "box/srv/repo")
        == .remote(RemoteHost(alias: "box"), path: "/srv/repo"))
  }

  @Test func remoteIDRoundTripsThroughParse() {
    let host = RemoteHost(alias: "box", username: "me", port: 2222)
    let id = RepositoryLocation.remote(host, path: "/srv/repo").id
    #expect(RepositoryLocation.parse(persistedID: id.rawValue) == .remote(host, path: "/srv/repo"))
  }

  @Test func normalizedRemotePathTrimsTrailingSlashes() {
    #expect(RepositoryLocation.normalizedRemotePath("/srv/repo/") == "/srv/repo")
    #expect(RepositoryLocation.normalizedRemotePath("  /srv/repo  ") == "/srv/repo")
    #expect(RepositoryLocation.normalizedRemotePath("/") == "/")
  }

  // MARK: - WorktreeLocation id derivation

  @Test func localGitWorktreeIDIsBarePath() {
    let location = WorktreeLocation.local(
      workingDirectory: URL(fileURLWithPath: "/repo/wt"),
      repositoryRoot: URL(fileURLWithPath: "/repo")
    )
    #expect(location.id == WorktreeID("/repo/wt"))
    #expect(location.localWorkingDirectory == URL(fileURLWithPath: "/repo/wt"))
  }

  @Test func remoteGitWorktreeIDBrandsHost() {
    let host = RemoteHost(alias: "box", port: 22)
    let location = WorktreeLocation.remote(host, workingDirectory: "/repo/wt", repositoryRoot: "/repo")
    #expect(location.id == WorktreeID("box:22/repo/wt"))
    #expect(location.localWorkingDirectory == nil)
    #expect(location.host == host)
  }

  // MARK: - Folder synthetic id (kind lives on Worktree, not the id)

  @Test func localFolderWorktreeIDIsTheRepositoryPath() {
    let repoURL = URL(fileURLWithPath: "/Users/me/notes", isDirectory: true)
    // The folder synthetic shares the path-derived id with its repo; git-vs-folder
    // is carried by `Worktree.kind`, not baked into the id.
    let id = Repository.folderWorktreeID(for: repoURL)
    #expect(id == WorktreeID("/Users/me/notes/"))
    #expect(id.rawValue == RepositoryLocation.local(repoURL).id.rawValue)
  }

  @Test func worktreeKindDrivesIsFolder() {
    let location = WorktreeLocation.local(
      workingDirectory: URL(fileURLWithPath: "/repo"),
      repositoryRoot: URL(fileURLWithPath: "/repo")
    )
    let folder = Worktree(location: location, kind: .folder, name: "repo", detail: "")
    let git = Worktree(location: location, kind: .git, name: "repo", detail: "")
    #expect(folder.isFolder)
    #expect(!git.isFolder)
    // Same location yields the same id regardless of kind.
    #expect(folder.id == git.id)
  }

  @Test func worktreeLocationExposesOwningRepositoryLocation() {
    let host = RemoteHost(alias: "box")
    let remote = WorktreeLocation.remote(host, workingDirectory: "/repo/wt", repositoryRoot: "/repo")
    #expect(remote.repositoryLocation.id == RepositoryID("box/repo"))
    let local = WorktreeLocation.local(
      workingDirectory: URL(fileURLWithPath: "/repo/wt"),
      repositoryRoot: URL(fileURLWithPath: "/repo", isDirectory: true)
    )
    #expect(local.repositoryLocation.id == RepositoryID("/repo/"))
  }
}
