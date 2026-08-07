import Foundation
import GhosttyKit
import Testing

@testable import supacode

@MainActor
struct TerminalSurfaceRecipeTests {
  private static func makeWorktree() -> Worktree {
    Worktree(
      id: WorktreeID("/tmp/recipe-fixture/wt"),
      name: "wt",
      detail: "detail",
      // Explicit hints: fileURLWithPath would stat the path and grow a
      // trailing slash the moment the directory exists on the test machine.
      workingDirectory: URL(filePath: "/tmp/recipe-fixture/wt", directoryHint: .notDirectory),
      repositoryRootURL: URL(filePath: "/tmp/recipe-fixture", directoryHint: .notDirectory)
    )
  }

  @Test func environmentCarriesIdentityMarkers() {
    let tabID = TerminalTabID()
    let surfaceID = UUID()
    let env = TerminalSurfaceRecipe.environment(
      for: Self.makeWorktree(),
      tabID: tabID,
      surfaceID: surfaceID,
      socketPath: "/tmp/socket"
    )
    // Slashes are deliberately encoded: downstream deeplinks embed these IDs.
    #expect(env["SUPACODE_REPO_ID"] == "%2Ftmp%2Frecipe-fixture")
    #expect(env["SUPACODE_WORKTREE_ID"] == "%2Ftmp%2Frecipe-fixture%2Fwt")
    #expect(env["SUPACODE_TAB_ID"] == tabID.rawValue.uuidString)
    #expect(env["SUPACODE_SURFACE_ID"] == surfaceID.uuidString)
    #expect(env["SUPACODE_SOCKET_PATH"] == "/tmp/socket")
    #expect(env["ZMX_DIR"] != nil)
  }

  @Test func environmentOmitsSocketWhenAbsent() {
    let env = TerminalSurfaceRecipe.environment(
      for: Self.makeWorktree(),
      tabID: TerminalTabID(),
      surfaceID: UUID(),
      socketPath: nil
    )
    #expect(env["SUPACODE_SOCKET_PATH"] == nil)
  }

  @Test func extraVariablesCannotOverrideTheZmxDirectoryLock() {
    let env = TerminalSurfaceRecipe.environment(
      for: Self.makeWorktree(),
      tabID: TerminalTabID(),
      surfaceID: UUID(),
      socketPath: nil,
      extraVariables: ["ZMX_DIR": "/evil", "SUPACODE_SCRIPT": "1"]
    )
    #expect(env["ZMX_DIR"] == ZmxSocketBudget.socketDir())
    #expect(env["SUPACODE_SCRIPT"] == "1")
  }

  @Test func bypassingZmxKeepsTheCommandVerbatim() {
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

  @Test func localLaunchDerivesTheSessionFromTheSurfaceID() {
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

  // MARK: - Surface plans.

  private static func makeRequest(
    state: TerminalContentState = TerminalContentState(workingDirectory: nil),
    origin: ContentOrigin = .tab
  ) -> ContentRequest {
    ContentRequest(
      worktreeID: makeWorktree().id,
      tabID: TerminalTabID(),
      contentID: ContentID(),
      initialState: state,
      origin: origin
    )
  }

  @Test func planMapsOriginsToSurfaceContexts() {
    let worktree = Self.makeWorktree()
    func context(of origin: ContentOrigin) -> ghostty_surface_context_e {
      TerminalSurfaceRecipe.plan(
        for: Self.makeRequest(origin: origin),
        worktree: worktree,
        socketPath: nil,
        zmxExecutablePath: nil
      ).context
    }
    #expect(context(of: .first) == GHOSTTY_SURFACE_CONTEXT_WINDOW)
    #expect(context(of: .tab) == GHOSTTY_SURFACE_CONTEXT_TAB)
    #expect(context(of: .restored) == GHOSTTY_SURFACE_CONTEXT_TAB)
    #expect(context(of: .split) == GHOSTTY_SURFACE_CONTEXT_SPLIT)
  }

  @Test func planPrefersThePersistedWorkingDirectory() {
    let worktree = Self.makeWorktree()
    let persisted = TerminalSurfaceRecipe.plan(
      for: Self.makeRequest(state: TerminalContentState(workingDirectory: "/tmp/elsewhere")),
      worktree: worktree,
      socketPath: nil,
      zmxExecutablePath: nil
    )
    #expect(persisted.workingDirectory?.path(percentEncoded: false).hasPrefix("/tmp/elsewhere") == true)
    let fallback = TerminalSurfaceRecipe.plan(
      for: Self.makeRequest(),
      worktree: worktree,
      socketPath: nil,
      zmxExecutablePath: nil
    )
    #expect(fallback.workingDirectory == worktree.workingDirectory)
  }

  @Test func planCarriesTheFrozenFontAndIdentityEnvironment() throws {
    let worktree = Self.makeWorktree()
    let grid = try #require(
      FrozenGrid.from(backingSize: CGSize(width: 800, height: 600), columns: 80, rows: 24, scale: 2, fontSize: 13)
    )
    let request = Self.makeRequest(
      state: TerminalContentState(workingDirectory: nil, frozenGrid: grid),
      origin: .restored
    )
    let plan = TerminalSurfaceRecipe.plan(
      for: request,
      worktree: worktree,
      socketPath: "/tmp/socket",
      zmxExecutablePath: "/usr/local/bin/zmx"
    )
    #expect(plan.fontSize == 13)
    #expect(plan.environment["SUPACODE_TAB_ID"] == request.tabID.rawValue.uuidString)
    #expect(plan.environment["SUPACODE_SURFACE_ID"] == request.contentID.rawValue.uuidString)
    // The re-attach targets the zmx session derived from the content identity.
    #expect(plan.commandWrapper.contains(ZmxSessionID.make(surfaceID: request.contentID.rawValue)))
  }
}
