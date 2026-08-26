import AppKit
import Dependencies
import DependenciesTestSupport
import Foundation
import GhosttyKit
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

  private func makeHost(layout: PaneLayout?, runtime: ContentRuntime = ContentRuntime()) -> WorktreeContentHost {
    let host = WorktreeContentHost(
      worktree: makeWorktree(),
      runtime: runtime,
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

  /// #828: a tracked blocking script alone must not shimmer the worktree row.
  /// Only genuine OSC-9 progress does, and a completed-parked script's lingering
  /// progress stays off the row.
  @Test func rowActivityBusyReflectsProgressNotScriptPresence() {
    #expect(!WorktreeContentHost.isTabActivityBusy(isCompletedBlockingScript: false, progressState: nil))
    #expect(
      WorktreeContentHost.isTabActivityBusy(
        isCompletedBlockingScript: false, progressState: GHOSTTY_PROGRESS_STATE_SET
      ))
    #expect(
      WorktreeContentHost.isTabActivityBusy(
        isCompletedBlockingScript: false, progressState: GHOSTTY_PROGRESS_STATE_INDETERMINATE
      ))
    #expect(
      !WorktreeContentHost.isTabActivityBusy(
        isCompletedBlockingScript: true, progressState: GHOSTTY_PROGRESS_STATE_SET
      ))
  }

  @Test(.dependencies) func blockingScriptCompletionLocksTheTabChrome() {
    let surfaceID = UUID()
    let tabID = TabID(rawValue: surfaceID)
    let runtime = ContentRuntime()
    let content = ChromeTabContent(id: ContentID(rawValue: surfaceID))
    #expect(runtime.provision(content, at: .fallback))
    let host = makeHost(layout: singleTabLayout(contentID: surfaceID), runtime: runtime)

    host.trackBlockingScript(kind: .archive, tabID: tabID, launchDirectory: nil)
    #expect(content.terminalChrome.isReadOnly == false)

    host.handleBlockingScriptCommandFinished(tabID: tabID, exitCode: 0)
    #expect(content.terminalChrome.isReadOnly)

    // Re-running the script unlocks the parked shell's replacement.
    host.trackBlockingScript(kind: .archive, tabID: tabID, launchDirectory: nil)
    #expect(content.terminalChrome.isReadOnly == false)
  }

  @Test func aReportedTitleLandsOnTheChromeAndRearmsPersistenceOnce() {
    let surfaceID = UUID()
    let contentID = ContentID(rawValue: surfaceID)
    let runtime = ContentRuntime()
    let content = ChromeTabContent(id: contentID)
    #expect(runtime.provision(content, at: .fallback))
    let host = makeHost(layout: singleTabLayout(contentID: surfaceID), runtime: runtime)
    var sentLayoutActions = 0
    var persistenceRearms = 0
    host.sendLayoutAction = { _ in sentLayoutActions += 1 }
    host.onReportedTitleChanged = { persistenceRearms += 1 }

    host.updateReportedTitle(for: contentID, title: "claude")
    // An unchanged report is dropped before it can touch the chrome.
    host.updateReportedTitle(for: contentID, title: "claude")

    #expect(content.terminalChrome.reportedTitle == "claude")
    #expect(persistenceRearms == 1)
    // The whole point: a title storm never reaches the store.
    #expect(sentLayoutActions == 0)
  }

  @Test(.dependencies) func anEmptyReportedTitleIsIgnoredSoTheLabelHoldsItsLastValue() {
    let surfaceID = UUID()
    let contentID = ContentID(rawValue: surfaceID)
    let runtime = ContentRuntime()
    let content = ChromeTabContent(id: contentID)
    #expect(runtime.provision(content, at: .fallback))
    let host = makeHost(layout: singleTabLayout(contentID: surfaceID), runtime: runtime)
    var persistenceRearms = 0
    host.onReportedTitleChanged = { persistenceRearms += 1 }

    host.updateReportedTitle(for: contentID, title: "~/project")
    // A shell that clears the title mid-command must not flash the label: the
    // empty and whitespace reports are dropped, keeping the last real title.
    host.updateReportedTitle(for: contentID, title: "")
    host.updateReportedTitle(for: contentID, title: "   ")

    #expect(content.terminalChrome.reportedTitle == "~/project")
    #expect(persistenceRearms == 1)
  }
}

/// Pins the render-host claim invariants the steal-proof mount depends on.
@MainActor
struct WorktreeContentRuntimeRenderHostTests {
  @Test func aNewerClaimInvalidatesTheOlderOne() {
    let runtime = ContentRuntime()
    let contentID = ContentID()
    let first = runtime.claimRenderHost(for: contentID)
    #expect(runtime.isCurrentRenderHost(first, for: contentID))
    let second = runtime.claimRenderHost(for: contentID)
    #expect(!runtime.isCurrentRenderHost(first, for: contentID))
    #expect(runtime.isCurrentRenderHost(second, for: contentID))
  }

  @Test func aClaimSurvivesRemovalForTheReattachFlow() {
    let runtime = ContentRuntime()
    let content = ChromeTabContent(id: ContentID())
    #expect(runtime.provision(content, at: .fallback))
    let claim = runtime.claimRenderHost(for: content.id)
    // Reattach removes and re-provisions the same ID under the live host.
    runtime.remove(content.id, tombstone: false)
    #expect(runtime.isCurrentRenderHost(claim, for: content.id))
  }

  @Test func confirmKillReleasesTheClaim() {
    let runtime = ContentRuntime()
    let content = ChromeTabContent(id: ContentID())
    #expect(runtime.provision(content, at: .fallback))
    let claim = runtime.claimRenderHost(for: content.id)
    runtime.remove(content.id, tombstone: true)
    runtime.confirmKill(content.id)
    #expect(!runtime.isCurrentRenderHost(claim, for: content.id))
  }
}
