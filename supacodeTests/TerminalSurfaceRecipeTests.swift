import Foundation
import Testing

@testable import supacode

@MainActor
struct TerminalSurfaceRecipeTests {
  private static func makeWorktree() -> Worktree {
    Worktree(
      id: WorktreeID("/tmp/repo/wt"),
      name: "wt",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
  }

  @Test @MainActor func environmentCarriesIdentityMarkers() {
    let tabID = TerminalTabID()
    let surfaceID = UUID()
    let env = TerminalSurfaceRecipe.environment(
      for: Self.makeWorktree(),
      tabID: tabID,
      surfaceID: surfaceID,
      socketPath: "/tmp/socket"
    )
    // Slashes are deliberately encoded: downstream deeplinks embed these IDs.
    #expect(env["SUPACODE_REPO_ID"] == "%2Ftmp%2Frepo")
    #expect(env["SUPACODE_WORKTREE_ID"] == "%2Ftmp%2Frepo%2Fwt")
    #expect(env["SUPACODE_TAB_ID"] == tabID.rawValue.uuidString)
    #expect(env["SUPACODE_SURFACE_ID"] == surfaceID.uuidString)
    #expect(env["SUPACODE_SOCKET_PATH"] == "/tmp/socket")
    #expect(env["ZMX_DIR"] != nil)
  }

  @Test @MainActor func environmentOmitsSocketWhenAbsent() {
    let env = TerminalSurfaceRecipe.environment(
      for: Self.makeWorktree(),
      tabID: TerminalTabID(),
      surfaceID: UUID(),
      socketPath: nil
    )
    #expect(env["SUPACODE_SOCKET_PATH"] == nil)
  }

  @Test @MainActor func extraVariablesCannotOverrideTheZmxDirectoryLock() {
    let env = TerminalSurfaceRecipe.environment(
      for: Self.makeWorktree(),
      tabID: TerminalTabID(),
      surfaceID: UUID(),
      socketPath: nil,
      extraVariables: ["ZMX_DIR": "/evil", "SUPACODE_SCRIPT": "1"]
    )
    #expect(env["ZMX_DIR"] != "/evil")
    #expect(env["SUPACODE_SCRIPT"] == "1")
  }

  @Test @MainActor func bypassingZmxKeepsTheCommandVerbatim() {
    let launch = TerminalSurfaceRecipe.launch(
      TerminalSurfaceRecipe.LaunchIntent(command: "./script.sh", initialInput: "input\n", bypassZmx: true),
      for: Self.makeWorktree(),
      surfaceID: UUID(),
      zmxExecutablePath: "/usr/local/bin/zmx"
    )
    #expect(launch.command == "./script.sh")
    #expect(launch.initialInput == "input\n")
    #expect(launch.commandWrapper.isEmpty)
    #expect(launch.usesZmx == false)
  }

  @Test @MainActor func localLaunchDerivesTheSessionFromTheSurfaceID() {
    let surfaceID = UUID()
    let launch = TerminalSurfaceRecipe.launch(
      TerminalSurfaceRecipe.LaunchIntent(),
      for: Self.makeWorktree(),
      surfaceID: surfaceID,
      zmxExecutablePath: "/usr/local/bin/zmx"
    )
    // The session name is the surface identity; hibernated wakes and the CLI
    // both address it by this derivation.
    #expect(launch.usesZmx)
    #expect(launch.commandWrapper.contains(ZmxSessionID.make(surfaceID: surfaceID)))
  }
}
