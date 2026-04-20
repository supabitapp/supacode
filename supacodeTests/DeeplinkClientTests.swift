import Foundation
import Testing

@testable import supacode

@MainActor
struct DeeplinkClientTests {
  private let parse = DeeplinkClient.liveValue.parse

  // MARK: - Open.

  @Test func emptyURLReturnsOpen() {
    let url = URL(string: "supacode://")!
    #expect(parse(url) == .open)
  }

  @Test func helpURLReturnsHelp() {
    let url = URL(string: "supacode://help")!
    #expect(parse(url) == .help)
  }

  @Test func wrongSchemeReturnsNil() {
    let url = URL(string: "https://worktree/abc/select")!
    #expect(parse(url) == nil)
  }

  // MARK: - Worktree actions.

  @Test func worktreeRun() {
    let encoded = "%2Ftmp%2Frepo%2Fwt-1"
    let url = URL(string: "supacode://worktree/\(encoded)/run")!
    #expect(parse(url) == .worktree(id: "/tmp/repo/wt-1", action: .run))
  }

  @Test func worktreeArchive() {
    let encoded = "%2Ftmp%2Frepo%2Fwt-1"
    let url = URL(string: "supacode://worktree/\(encoded)/archive")!
    #expect(parse(url) == .worktree(id: "/tmp/repo/wt-1", action: .archive))
  }

  @Test func worktreeUnarchive() {
    let encoded = "%2Ftmp%2Frepo%2Fwt-1"
    let url = URL(string: "supacode://worktree/\(encoded)/unarchive")!
    #expect(parse(url) == .worktree(id: "/tmp/repo/wt-1", action: .unarchive))
  }

  @Test func worktreeDelete() {
    let encoded = "%2Ftmp%2Frepo%2Fwt-1"
    let url = URL(string: "supacode://worktree/\(encoded)/delete")!
    #expect(parse(url) == .worktree(id: "/tmp/repo/wt-1", action: .delete))
  }

  @Test func worktreePin() {
    let encoded = "%2Ftmp%2Frepo%2Fwt-1"
    let url = URL(string: "supacode://worktree/\(encoded)/pin")!
    #expect(parse(url) == .worktree(id: "/tmp/repo/wt-1", action: .pin))
  }

  @Test func worktreeUnpin() {
    let encoded = "%2Ftmp%2Frepo%2Fwt-1"
    let url = URL(string: "supacode://worktree/\(encoded)/unpin")!
    #expect(parse(url) == .worktree(id: "/tmp/repo/wt-1", action: .unpin))
  }

  @Test func worktreeMissingActionDefaultsToSelect() {
    let encoded = "%2Ftmp%2Frepo%2Fwt-1"
    let url = URL(string: "supacode://worktree/\(encoded)")!
    #expect(parse(url) == .worktree(id: "/tmp/repo/wt-1", action: .select))
  }

  @Test func worktreeUnknownActionReturnsNil() {
    let encoded = "%2Ftmp%2Frepo%2Fwt-1"
    let url = URL(string: "supacode://worktree/\(encoded)/explode")!
    #expect(parse(url) == nil)
  }

  // MARK: - Tab actions.

  @Test func worktreeTabWithValidUUID() {
    let encoded = "%2Ftmp%2Frepo%2Fwt-1"
    let tabUUID = UUID(uuidString: "550E8400-E29B-41D4-A716-446655440000")!
    let url = URL(string: "supacode://worktree/\(encoded)/tab/550E8400-E29B-41D4-A716-446655440000")!
    #expect(parse(url) == .worktree(id: "/tmp/repo/wt-1", action: .tab(tabID: tabUUID)))
  }

  @Test func worktreeTabWithInvalidUUIDReturnsNil() {
    let encoded = "%2Ftmp%2Frepo%2Fwt-1"
    let url = URL(string: "supacode://worktree/\(encoded)/tab/not-a-uuid")!
    #expect(parse(url) == nil)
  }

  @Test func worktreeTabWithoutTabIDReturnsNil() {
    let encoded = "%2Ftmp%2Frepo%2Fwt-1"
    let url = URL(string: "supacode://worktree/\(encoded)/tab")!
    #expect(parse(url) == nil)
  }

  @Test func worktreeTabNewWithoutInput() {
    let encoded = "%2Ftmp%2Frepo%2Fwt-1"
    let url = URL(string: "supacode://worktree/\(encoded)/tab/new")!
    #expect(parse(url) == .worktree(id: "/tmp/repo/wt-1", action: .tabNew(input: nil, id: nil)))
  }

  @Test func worktreeTabNewWithInput() {
    let encoded = "%2Ftmp%2Frepo%2Fwt-1"
    let url = URL(string: "supacode://worktree/\(encoded)/tab/new?input=echo%20hello")!
    #expect(parse(url) == .worktree(id: "/tmp/repo/wt-1", action: .tabNew(input: "echo hello", id: nil)))
  }

  @Test func worktreeTabDestroy() {
    let encoded = "%2Ftmp%2Frepo%2Fwt-1"
    let tabUUID = UUID(uuidString: "550E8400-E29B-41D4-A716-446655440000")!
    let url = URL(string: "supacode://worktree/\(encoded)/tab/\(tabUUID.uuidString)/destroy")!
    #expect(parse(url) == .worktree(id: "/tmp/repo/wt-1", action: .tabDestroy(tabID: tabUUID)))
  }

  // MARK: - Surface actions.

  @Test func worktreeSurfaceFocus() {
    let encoded = "%2Ftmp%2Frepo%2Fwt-1"
    let tabUUID = UUID(uuidString: "550E8400-E29B-41D4-A716-446655440000")!
    let surfaceUUID = UUID(uuidString: "660E8400-E29B-41D4-A716-446655440000")!
    let url = URL(
      string: "supacode://worktree/\(encoded)/tab/\(tabUUID.uuidString)/surface/\(surfaceUUID.uuidString)"
    )!
    #expect(
      parse(url)
        == .worktree(id: "/tmp/repo/wt-1", action: .surface(tabID: tabUUID, surfaceID: surfaceUUID, input: nil))
    )
  }

  @Test func worktreeSurfaceFocusWithInput() {
    let encoded = "%2Ftmp%2Frepo%2Fwt-1"
    let tabUUID = UUID(uuidString: "550E8400-E29B-41D4-A716-446655440000")!
    let surfaceUUID = UUID(uuidString: "660E8400-E29B-41D4-A716-446655440000")!
    let url = URL(
      string: "supacode://worktree/\(encoded)/tab/\(tabUUID.uuidString)/surface/\(surfaceUUID.uuidString)?input=ls"
    )!
    #expect(
      parse(url)
        == .worktree(id: "/tmp/repo/wt-1", action: .surface(tabID: tabUUID, surfaceID: surfaceUUID, input: "ls"))
    )
  }

  @Test func worktreeSurfaceSplitHorizontal() {
    let encoded = "%2Ftmp%2Frepo%2Fwt-1"
    let tabUUID = UUID(uuidString: "550E8400-E29B-41D4-A716-446655440000")!
    let surfaceUUID = UUID(uuidString: "660E8400-E29B-41D4-A716-446655440000")!
    let base = "supacode://worktree/\(encoded)/tab/\(tabUUID.uuidString)"
    let url = URL(string: "\(base)/surface/\(surfaceUUID.uuidString)/split?direction=horizontal")!
    #expect(
      parse(url)
        == .worktree(
          id: "/tmp/repo/wt-1",
          action: .surfaceSplit(
            tabID: tabUUID, surfaceID: surfaceUUID, direction: .horizontal, input: nil, id: nil
          ),
        )
    )
  }

  @Test func worktreeSurfaceSplitVerticalWithInput() {
    let encoded = "%2Ftmp%2Frepo%2Fwt-1"
    let tabUUID = UUID(uuidString: "550E8400-E29B-41D4-A716-446655440000")!
    let surfaceUUID = UUID(uuidString: "660E8400-E29B-41D4-A716-446655440000")!
    let base = "supacode://worktree/\(encoded)/tab/\(tabUUID.uuidString)"
    let url = URL(string: "\(base)/surface/\(surfaceUUID.uuidString)/split?direction=vertical&input=echo%20hi")!
    #expect(
      parse(url)
        == .worktree(
          id: "/tmp/repo/wt-1",
          action: .surfaceSplit(
            tabID: tabUUID, surfaceID: surfaceUUID, direction: .vertical, input: "echo hi", id: nil),
        )
    )
  }

  @Test func worktreeSurfaceSplitDefaultsToHorizontal() {
    let encoded = "%2Ftmp%2Frepo%2Fwt-1"
    let tabUUID = UUID(uuidString: "550E8400-E29B-41D4-A716-446655440000")!
    let surfaceUUID = UUID(uuidString: "660E8400-E29B-41D4-A716-446655440000")!
    let url = URL(
      string:
        "supacode://worktree/\(encoded)/tab/\(tabUUID.uuidString)/surface/\(surfaceUUID.uuidString)/split"
    )!
    #expect(
      parse(url)
        == .worktree(
          id: "/tmp/repo/wt-1",
          action: .surfaceSplit(tabID: tabUUID, surfaceID: surfaceUUID, direction: .horizontal, input: nil, id: nil),
        )
    )
  }

  @Test func worktreeSurfaceInvalidUUIDReturnsNil() {
    let encoded = "%2Ftmp%2Frepo%2Fwt-1"
    let tabUUID = UUID(uuidString: "550E8400-E29B-41D4-A716-446655440000")!
    let url = URL(
      string: "supacode://worktree/\(encoded)/tab/\(tabUUID.uuidString)/surface/not-a-uuid"
    )!
    #expect(parse(url) == nil)
  }

  // MARK: - Repo actions.

  @Test func repoOpen() {
    let url = URL(string: "supacode://repo/open?path=%2Ftmp%2Fmy-repo")!
    #expect(parse(url) == .repoOpen(path: URL(fileURLWithPath: "/tmp/my-repo")))
  }

  @Test func repoOpenMissingPathReturnsNil() {
    let url = URL(string: "supacode://repo/open")!
    #expect(parse(url) == nil)
  }

  @Test func repoWorktreeNewWithBranch() {
    let repoEncoded = "%2Ftmp%2Frepo"
    let url = URL(
      string: "supacode://repo/\(repoEncoded)/worktree/new?branch=feature-x&base=main&fetch=true"
    )!
    #expect(
      parse(url)
        == .repoWorktreeNew(
          repositoryID: "/tmp/repo",
          branch: "feature-x",
          baseRef: "main",
          fetchOrigin: true
        )
    )
  }

  @Test func repoWorktreeNewWithoutBranch() {
    let repoEncoded = "%2Ftmp%2Frepo"
    let url = URL(string: "supacode://repo/\(repoEncoded)/worktree/new")!
    #expect(
      parse(url)
        == .repoWorktreeNew(
          repositoryID: "/tmp/repo",
          branch: nil,
          baseRef: nil,
          fetchOrigin: false
        )
    )
  }

  @Test func repoUnknownPathReturnsNil() {
    let repoEncoded = "%2Ftmp%2Frepo"
    let url = URL(string: "supacode://repo/\(repoEncoded)/unknown")!
    #expect(parse(url) == nil)
  }

  // MARK: - Settings.

  @Test func settingsWithoutSection() {
    let url = URL(string: "supacode://settings")!
    #expect(parse(url) == .settings(section: nil))
  }

  @Test func settingsWithUnknownSectionReturnsNilSection() {
    let url = URL(string: "supacode://settings/nonexistent")!
    #expect(parse(url) == .settings(section: nil))
  }

  @Test func settingsWithSection() {
    let url = URL(string: "supacode://settings/worktrees")!
    #expect(parse(url) == .settings(section: .worktrees))
  }

  @Test func settingsDeveloperSection() {
    let url = URL(string: "supacode://settings/developer")!
    #expect(parse(url) == .settings(section: .developer))
  }

  @Test func settingsCodingAgentsBackwardCompat() {
    let url = URL(string: "supacode://settings/codingAgents")!
    #expect(parse(url) == .settings(section: .codingAgents))
  }

  @Test func settingsRepoWithValidID() {
    let url = URL(string: "supacode://settings/repo/%2Ftmp%2Frepo")!
    #expect(parse(url) == .settingsRepo(repositoryID: "/tmp/repo"))
  }

  @Test func settingsRepoWithMissingIDReturnsNil() {
    let url = URL(string: "supacode://settings/repo")!
    #expect(parse(url) == nil)
  }

  // MARK: - Surface destroy.

  @Test func worktreeSurfaceDestroy() {
    let encoded = "%2Ftmp%2Frepo%2Fwt-1"
    let tabUUID = UUID(uuidString: "550E8400-E29B-41D4-A716-446655440000")!
    let surfaceUUID = UUID(uuidString: "660E8400-E29B-41D4-A716-446655440000")!
    let base = "supacode://worktree/\(encoded)/tab/\(tabUUID.uuidString)"
    let url = URL(string: "\(base)/surface/\(surfaceUUID.uuidString)/destroy")!
    #expect(
      parse(url)
        == .worktree(
          id: "/tmp/repo/wt-1",
          action: .surfaceDestroy(tabID: tabUUID, surfaceID: surfaceUUID),
        )
    )
  }

  // MARK: - Tab new with ID query parameter.

  @Test func worktreeTabNewWithID() {
    let encoded = "%2Ftmp%2Frepo%2Fwt-1"
    let tabID = UUID(uuidString: "770E8400-E29B-41D4-A716-446655440000")!
    let url = URL(string: "supacode://worktree/\(encoded)/tab/new?id=\(tabID.uuidString)")!
    #expect(parse(url) == .worktree(id: "/tmp/repo/wt-1", action: .tabNew(input: nil, id: tabID)))
  }

  // MARK: - Surface split with ID query parameter.

  @Test func worktreeSurfaceSplitWithID() {
    let encoded = "%2Ftmp%2Frepo%2Fwt-1"
    let tabUUID = UUID(uuidString: "550E8400-E29B-41D4-A716-446655440000")!
    let surfaceUUID = UUID(uuidString: "660E8400-E29B-41D4-A716-446655440000")!
    let newID = UUID(uuidString: "880E8400-E29B-41D4-A716-446655440000")!
    let base = "supacode://worktree/\(encoded)/tab/\(tabUUID.uuidString)"
    let url = URL(string: "\(base)/surface/\(surfaceUUID.uuidString)/split?id=\(newID.uuidString)")!
    #expect(
      parse(url)
        == .worktree(
          id: "/tmp/repo/wt-1",
          action: .surfaceSplit(tabID: tabUUID, surfaceID: surfaceUUID, direction: .horizontal, input: nil, id: newID),
        )
    )
  }

  // MARK: - Invalid split direction.

  @Test func worktreeSurfaceSplitInvalidDirectionReturnsNil() {
    let encoded = "%2Ftmp%2Frepo%2Fwt-1"
    let tabUUID = UUID(uuidString: "550E8400-E29B-41D4-A716-446655440000")!
    let surfaceUUID = UUID(uuidString: "660E8400-E29B-41D4-A716-446655440000")!
    let base = "supacode://worktree/\(encoded)/tab/\(tabUUID.uuidString)"
    let url = URL(string: "\(base)/surface/\(surfaceUUID.uuidString)/split?direction=diagonal")!
    #expect(parse(url) == nil)
  }

  // MARK: - Repo open edge cases.

  @Test func repoOpenWithEmptyPathReturnsNil() {
    let url = URL(string: "supacode://repo/open?path=")!
    #expect(parse(url) == nil)
  }

  @Test func repoOpenWithRelativePathReturnsNil() {
    let url = URL(string: "supacode://repo/open?path=relative/path")!
    #expect(parse(url) == nil)
  }

  // MARK: - Worktree stop.

  @Test func worktreeStop() {
    let encoded = "%2Ftmp%2Frepo%2Fwt-1"
    let url = URL(string: "supacode://worktree/\(encoded)/stop")!
    #expect(parse(url) == .worktree(id: "/tmp/repo/wt-1", action: .stop))
  }

  // MARK: - Named script actions.

  @Test func worktreeScriptRun() {
    let encoded = "%2Ftmp%2Frepo%2Fwt-1"
    let scriptID = UUID(uuidString: "AA0E8400-E29B-41D4-A716-446655440000")!
    let url = URL(string: "supacode://worktree/\(encoded)/script/\(scriptID.uuidString)/run")!
    #expect(
      parse(url)
        == .worktree(id: "/tmp/repo/wt-1", action: .runScript(scriptID: scriptID))
    )
  }

  @Test func worktreeScriptStop() {
    let encoded = "%2Ftmp%2Frepo%2Fwt-1"
    let scriptID = UUID(uuidString: "AA0E8400-E29B-41D4-A716-446655440000")!
    let url = URL(string: "supacode://worktree/\(encoded)/script/\(scriptID.uuidString)/stop")!
    #expect(
      parse(url)
        == .worktree(id: "/tmp/repo/wt-1", action: .stopScript(scriptID: scriptID))
    )
  }

  @Test func worktreeScriptInvalidUUIDReturnsNil() {
    let encoded = "%2Ftmp%2Frepo%2Fwt-1"
    let url = URL(string: "supacode://worktree/\(encoded)/script/not-a-uuid/run")!
    #expect(parse(url) == nil)
  }

  @Test func worktreeScriptUnknownVerbReturnsNil() {
    let encoded = "%2Ftmp%2Frepo%2Fwt-1"
    let scriptID = UUID(uuidString: "AA0E8400-E29B-41D4-A716-446655440000")!
    let url = URL(string: "supacode://worktree/\(encoded)/script/\(scriptID.uuidString)/explode")!
    #expect(parse(url) == nil)
  }

  @Test func worktreeScriptMissingVerbReturnsNil() {
    let encoded = "%2Ftmp%2Frepo%2Fwt-1"
    let scriptID = UUID(uuidString: "AA0E8400-E29B-41D4-A716-446655440000")!
    let url = URL(string: "supacode://worktree/\(encoded)/script/\(scriptID.uuidString)")!
    #expect(parse(url) == nil)
  }

  @Test func worktreeScriptMissingIDReturnsNil() {
    let encoded = "%2Ftmp%2Frepo%2Fwt-1"
    let url = URL(string: "supacode://worktree/\(encoded)/script")!
    #expect(parse(url) == nil)
  }

  // MARK: - Worktree with no ID.

  @Test func worktreeWithNoIDReturnsNil() {
    let url = URL(string: "supacode://worktree")!
    #expect(parse(url) == nil)
  }

  // MARK: - Trailing slash normalization.

  @Test func worktreeIDWithTrailingSlashIsNormalized() {
    let encoded = "%2Ftmp%2Frepo%2Fwt-1%2F"
    let url = URL(string: "supacode://worktree/\(encoded)")!
    #expect(parse(url) == .worktree(id: "/tmp/repo/wt-1", action: .select))
  }

  // MARK: - Unknown host.

  @Test func unknownHostReturnsNil() {
    let url = URL(string: "supacode://unknown/something")!
    #expect(parse(url) == nil)
  }
}
