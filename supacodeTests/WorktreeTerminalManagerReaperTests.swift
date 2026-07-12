import Dependencies
import Foundation
import Testing

@testable import supacode

@MainActor
struct WorktreeTerminalManagerReaperTests {
  /// Builds a manager whose injected zmx client records every kill and serves
  /// the supplied `ls` listing (nil = probe failed).
  private func makeManager(
    listing: [ZmxSessionListParser.Entry]?,
    killed: LockIsolated<[String]>
  ) -> WorktreeTerminalManager {
    withDependencies {
      $0.zmxClient = ZmxClient(
        executableURL: { nil },
        isBundled: { true },
        killSession: { id in killed.withValue { $0.append(id) } },
        killRemoteSession: { _, _ in },
        listSessionsWithClients: { listing }
      )
    } operation: {
      WorktreeTerminalManager(runtime: GhosttyRuntime())
    }
  }

  private func session(for surfaceID: UUID) -> String {
    ZmxSessionID.make(surfaceID: surfaceID)
  }

  @Test func reapSparesAttachedOrphanEvenWhenUnknown() async {
    let attached = UUID()
    let idle = UUID()
    let killed = LockIsolated<[String]>([])
    let manager = makeManager(
      listing: [
        .init(name: session(for: attached), clients: 1),
        .init(name: session(for: idle), clients: 0),
      ],
      killed: killed
    )

    await manager.reapOrphanSessions(knownSurfaceIDs: [])

    #expect(killed.value == [session(for: idle)])
  }

  @Test func reapSkipsErrAndUnreachableSessions() async {
    let unreachable = UUID()
    let killed = LockIsolated<[String]>([])
    let manager = makeManager(
      listing: [.init(name: session(for: unreachable), clients: nil)],
      killed: killed
    )

    await manager.reapOrphanSessions(knownSurfaceIDs: [])

    #expect(killed.value.isEmpty)
  }

  @Test func reapKillsNothingWhenProbeUnavailable() async {
    let idle = UUID()
    let killed = LockIsolated<[String]>([])
    let manager = makeManager(listing: nil, killed: killed)

    await manager.reapOrphanSessions(knownSurfaceIDs: [idle])

    #expect(killed.value.isEmpty)
  }

  @Test func terminateKillsTrackedEvenWithLiveClientsButSparesUntrackedInUse() async {
    let killed = LockIsolated<[String]>([])
    let listing = LockIsolated<[ZmxSessionListParser.Entry]?>([])
    let manager = withDependencies {
      $0.zmxClient = ZmxClient(
        executableURL: { nil },
        isBundled: { true },
        killSession: { id in killed.withValue { $0.append(id) } },
        killRemoteSession: { _, _ in },
        listSessionsWithClients: { listing.value }
      )
    } operation: {
      WorktreeTerminalManager(runtime: GhosttyRuntime())
    }

    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    guard let tabID = state.createTab(focusing: false),
      let surface = state.splitTree(for: tabID).root?.leftmostLeaf()
    else {
      Issue.record("Expected a tab and surface")
      return
    }
    let trackedSurfaceID = surface.id
    let trackedSession = session(for: trackedSurfaceID)
    let untrackedSession = session(for: UUID())
    // The tracked session reports clients>0 (must still die) and an untracked
    // session is in use (must be spared).
    listing.setValue([
      .init(name: trackedSession, clients: 2),
      .init(name: untrackedSession, clients: 3),
    ])

    await manager.terminateAllSessions()

    #expect(killed.value == [trackedSession])
  }

  private func makeWorktree(id: String = "/tmp/repo/wt-1") -> Worktree {
    let name = URL(fileURLWithPath: id).lastPathComponent
    return Worktree(
      id: WorktreeID(id),
      name: name,
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
  }
}
