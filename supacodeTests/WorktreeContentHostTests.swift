import Dependencies
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Sharing
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct WorktreeContentHostTests {
  private func makeWorktree(id: String = "/tmp/repo/wt-host") -> Worktree {
    Worktree(
      id: WorktreeID(id),
      name: URL(fileURLWithPath: id).lastPathComponent,
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
  }

  private func singleTabLayout(contentID: UUID) -> PaneLayout {
    let paneID = PaneID()
    let tabID = TabID(rawValue: contentID)
    return PaneLayout(
      tree: SplitTree(view: paneID),
      panes: [
        Pane(
          id: paneID,
          tabs: [
            TabItem(
              id: tabID,
              title: "Tab",
              content: ContentSnapshot(
                id: ContentID(rawValue: contentID),
                state: .terminal(TerminalContentState(workingDirectory: nil))
              )
            )
          ],
          selectedTabID: tabID
        )
      ],
      focusedPaneID: paneID
    )
  }

  private func makeHost(layout: PaneLayout?) -> WorktreeContentHost {
    let host = WorktreeContentHost(
      worktree: makeWorktree(),
      runtime: ContentRuntime(),
      clock: ContinuousClock(),
      runSetupScript: false
    )
    host.layout = { layout }
    return host
  }

  private func append(_ titles: some Sequence<String>, to host: WorktreeContentHost, surfaceID: UUID) {
    withDependencies {
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    } operation: {
      for title in titles {
        host.appendNotification(title: title, body: "body", surfaceID: surfaceID)
      }
    }
  }

  @Test(.dependencies) func retentionTrimKeepsTheNewestUnread() {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.notificationRetentionLimit = .oneHundred }
    let surfaceID = UUID()
    let host = makeHost(layout: singleTabLayout(contentID: surfaceID))
    host.registerSurfaceState(for: surfaceID)

    append((0...100).map { "N\($0)" }, to: host, surfaceID: surfaceID)

    #expect(host.notifications.count == 100)
    // Every entry is unread, so the OLDEST drops and the newest survives.
    #expect(host.notifications.first?.title == "N100")
    #expect(!host.notifications.contains { $0.title == "N0" })
  }

  @Test(.dependencies) func retentionTrimDropsReadBeforeUnreadRegardlessOfAge() throws {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.notificationRetentionLimit = .oneHundred }
    let surfaceID = UUID()
    let host = makeHost(layout: singleTabLayout(contentID: surfaceID))
    host.registerSurfaceState(for: surfaceID)

    append((0...99).map { "N\($0)" }, to: host, surfaceID: surfaceID)
    let read = try #require(host.notifications.first { $0.title == "N50" })
    host.markNotificationRead(id: read.id)
    append(["N100"], to: host, surfaceID: surfaceID)

    #expect(host.notifications.count == 100)
    // The read entry goes first, even though older unread entries exist.
    #expect(!host.notifications.contains { $0.title == "N50" })
    #expect(host.notifications.contains { $0.title == "N0" })
    #expect(host.notifications.first?.title == "N100")
  }

  @Test(.dependencies) func unseenCounterCountsFromRegistrationAtProvision() {
    let surfaceID = UUID()
    let host = makeHost(layout: singleTabLayout(contentID: surfaceID))
    // Provision-time registration: without it the increment would no-op.
    host.registerSurfaceState(for: surfaceID)

    append(["Ping"], to: host, surfaceID: surfaceID)

    #expect(host.surfaceStates[surfaceID]?.unseenNotificationCount == 1)
    #expect(host.hasUnseenNotification)
  }
}
