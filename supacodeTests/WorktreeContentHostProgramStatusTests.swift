import Clocks
import Dependencies
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Sharing
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct WorktreeContentHostProgramStatusTests {
  private let surfaceID = UUID()

  private func makeHost(clock: any Clock<Duration> = ContinuousClock()) -> WorktreeContentHost {
    let paneID = PaneID()
    let tabID = TabID(rawValue: surfaceID)
    let layout = PaneLayout(
      tree: SplitTree(view: paneID),
      panes: [
        Pane(
          id: paneID,
          tabs: [
            TabItem(
              id: tabID,
              title: "Tab",
              content: ContentSnapshot(
                id: ContentID(rawValue: surfaceID),
                state: .terminal(TerminalContentState(workingDirectory: nil))
              )
            )
          ],
          selectedTabID: tabID
        )
      ],
      focusedPaneID: paneID
    )
    let host = WorktreeContentHost(
      worktree: Worktree(
        id: WorktreeID("/tmp/repo/wt-program-status"),
        name: "wt-program-status",
        detail: "detail",
        workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-program-status"),
        repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
      ),
      runtime: ContentRuntime(),
      clock: clock,
      runSetupScript: false
    )
    host.layout = { layout }
    host.registerSurfaceState(for: surfaceID)
    return host
  }

  private func send(_ report: ProgramStatusReport, to host: WorktreeContentHost) {
    withDependencies {
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    } operation: {
      host.handleProgramStatus(surfaceID: surfaceID, report: report)
    }
  }

  private func dormant(_ body: String, to host: WorktreeContentHost) {
    withDependencies {
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    } operation: {
      host.handleDormantOSCSequence(
        surfaceID: surfaceID, sequence: ZmxOSCSequence(code: 7501, payload: Array(body.utf8)))
    }
  }

  // MARK: - Forwarding.

  @Test(.dependencies) func everyReportIsForwardedWithItsSurface() {
    let host = makeHost()
    var forwarded: [(UUID, ProgramStatusReport)] = []
    host.onProgramStatus = { forwarded.append(($0, $1)) }
    let child = ProgramStatusReport(state: .working, id: "sub", app: "codex")

    send(ProgramStatusReport(state: .working, app: "codex"), to: host)
    send(child, to: host)

    #expect(forwarded.map(\.0) == [surfaceID, surfaceID])
    #expect(forwarded.last?.1 == child)
  }

  @Test(.dependencies) func reportForAnUnknownSurfaceIsDropped() {
    let host = makeHost()
    var forwarded = 0
    host.onProgramStatus = { _, _ in forwarded += 1 }

    host.handleProgramStatus(surfaceID: UUID(), report: ProgramStatusReport(state: .done, app: "codex"))

    #expect(forwarded == 0)
    #expect(host.notifications.isEmpty)
  }

  @Test(.dependencies) func returningPromptIsForwarded() {
    let host = makeHost()
    var prompts: [UUID] = []
    host.onProgramStatusPromptReturned = { prompts.append($0) }

    host.handleProgramStatusPromptReturned(surfaceID: surfaceID)

    #expect(prompts == [surfaceID])
  }

  // MARK: - Dormant sessions.

  @Test(.dependencies) func dormantSequenceIsParsedAndForwarded() {
    let host = makeHost()
    var forwarded: [ProgramStatusReport] = []
    host.onProgramStatus = { forwarded.append($1) }

    dormant("state=blocked:kind=question:app=claude-code", to: host)

    #expect(forwarded == [ProgramStatusReport(state: .blocked, kind: .question, app: "claude-code")])
  }

  @Test(.dependencies, arguments: ["?", "state=bogus", "state=clear:id=a@b", ""])
  func dormantSequenceTheSpecificationDiscardsIsDropped(_ body: String) {
    let host = makeHost()
    var forwarded = 0
    host.onProgramStatus = { _, _ in forwarded += 1 }

    dormant(body, to: host)

    #expect(forwarded == 0)
  }

  @Test(.dependencies) func dormantCommandEndIsAReturningPrompt() {
    let host = makeHost()
    var prompts: [UUID] = []
    host.onProgramStatusPromptReturned = { prompts.append($0) }

    for payload in ["D;0", "D", "A", "B", "C"] {
      host.handleDormantOSCSequence(
        surfaceID: surfaceID, sequence: ZmxOSCSequence(code: 133, payload: Array(payload.utf8)))
    }

    #expect(prompts == [surfaceID, surfaceID])
  }

  @Test(.dependencies) func dormantSequenceThatIsNotUTF8IsDropped() {
    let host = makeHost()
    var forwarded = 0
    host.onProgramStatus = { _, _ in forwarded += 1 }

    host.handleDormantOSCSequence(surfaceID: surfaceID, sequence: ZmxOSCSequence(code: 7501, payload: [0xFF, 0xFE]))

    #expect(forwarded == 0)
  }

  // MARK: - Notifications.

  @Test(.dependencies) func doneNotifiesOnce() {
    let host = makeHost()

    send(ProgramStatusReport(state: .working, app: "claude-code"), to: host)
    send(ProgramStatusReport(state: .done, app: "claude-code"), to: host)
    send(ProgramStatusReport(state: .done, app: "claude-code"), to: host)

    #expect(host.notifications.map(\.title) == ["Claude Code"])
    #expect(host.notifications.map(\.body) == ["Finished"])
  }

  @Test(.dependencies) func notificationUsesTheReportedTitleAndMessage() {
    let host = makeHost()

    send(
      ProgramStatusReport(state: .blocked, kind: .permission, app: "codex", title: "Deploy", message: "Run rm?"),
      to: host
    )

    #expect(host.notifications.first?.title == "Deploy")
    #expect(host.notifications.first?.body == "Run rm?")
  }

  @Test(.dependencies) func eachNewAttentionStateNotifies() async {
    let clock = TestClock()
    let host = makeHost(clock: clock)

    for state in [ProgramStatusReport.State.blocked, .working, .blocked, .error, .done] {
      send(ProgramStatusReport(state: state, app: "pi"), to: host)
      await clock.advance(by: AgentSignal.programStatusNotificationInterval)
    }

    #expect(host.notifications.count == 4)
  }

  @Test(.dependencies) func notificationsFromOneSurfaceAreRateLimited() async {
    // A program flapping between working and blocked must not flood the log.
    let clock = TestClock()
    let host = makeHost(clock: clock)
    var forwarded = 0
    host.onProgramStatus = { _, _ in forwarded += 1 }

    for state in [ProgramStatusReport.State.blocked, .working, .blocked, .working, .done] {
      send(ProgramStatusReport(state: state, app: "codex"), to: host)
      await clock.advance(by: .milliseconds(500))
    }
    #expect(host.notifications.count == 1)
    #expect(forwarded == 5)

    await clock.advance(by: AgentSignal.programStatusNotificationInterval)
    send(ProgramStatusReport(state: .blocked, app: "codex"), to: host)
    #expect(host.notifications.count == 2)
  }

  @Test(.dependencies) func clearResetsSoTheNextDoneNotifiesAgain() async {
    let clock = TestClock()
    let host = makeHost(clock: clock)

    send(ProgramStatusReport(state: .done, app: "opencode"), to: host)
    send(ProgramStatusReport(state: .clear), to: host)
    await clock.advance(by: AgentSignal.programStatusNotificationInterval)
    send(ProgramStatusReport(state: .done, app: "opencode"), to: host)

    #expect(host.notifications.count == 2)
  }

  @Test(.dependencies) func returningPromptResetsATransientState() async {
    let clock = TestClock()
    let host = makeHost(clock: clock)

    send(ProgramStatusReport(state: .blocked, app: "omp"), to: host)
    host.handleProgramStatusPromptReturned(surfaceID: surfaceID)
    await clock.advance(by: AgentSignal.programStatusNotificationInterval)
    send(ProgramStatusReport(state: .blocked, app: "omp"), to: host)

    #expect(host.notifications.count == 2)
  }

  @Test(.dependencies) func returningPromptKeepsADoneStateSoItDoesNotRenotify() {
    let host = makeHost()

    send(ProgramStatusReport(state: .done, app: "omp"), to: host)
    host.handleProgramStatusPromptReturned(surfaceID: surfaceID)
    send(ProgramStatusReport(state: .done, app: "omp"), to: host)

    #expect(host.notifications.count == 1)
  }

  @Test(.dependencies) func childRecordsNeverNotify() {
    let host = makeHost()

    send(ProgramStatusReport(state: .done, id: "subagent", app: "claude-code"), to: host)

    #expect(host.notifications.isEmpty)
  }

  @Test(.dependencies) func richNotificationsOffLeavesItToTheAgentsOwnAlert() {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.richAgentNotificationsEnabled = false }
    let host = makeHost()
    var forwarded = 0
    host.onProgramStatus = { _, _ in forwarded += 1 }

    send(ProgramStatusReport(state: .done, app: "claude-code"), to: host)

    #expect(host.notifications.isEmpty)
    #expect(forwarded == 1)
  }

  @Test(.dependencies) func dormantDoneNotifies() {
    let host = makeHost()

    dormant("state=done:app=codex:msg=\(Data("All green".utf8).base64EncodedString())", to: host)

    #expect(host.notifications.first?.title == "Codex")
    #expect(host.notifications.first?.body == "All green")
  }

  @Test(.dependencies) func closingTheSurfaceForgetsItsState() {
    let host = makeHost()
    send(ProgramStatusReport(state: .done, app: "codex"), to: host)

    host.cleanupSurfaceState(for: surfaceID)
    host.registerSurfaceState(for: surfaceID)
    send(ProgramStatusReport(state: .done, app: "codex"), to: host)

    #expect(host.notifications.count == 2)
  }
}

struct ProgramStatusNotificationTests {
  private func notification(
    previous: ProgramStatusReport.State? = nil, _ report: ProgramStatusReport
  ) -> (title: String, body: String)? {
    AgentSignal.programStatusNotification(previous: previous, report: report)
  }

  @Test(arguments: [
    (ProgramStatusReport.Kind?.none, "Waiting for you"),
    (.permission, "Needs your permission"),
    (.question, "Has a question"),
    (.auth, "Needs you to sign in"),
  ])
  func blockedFallsBackToItsKind(_ kind: ProgramStatusReport.Kind?, _ body: String) {
    let result = notification(ProgramStatusReport(state: .blocked, kind: kind, app: "claude-code"))

    #expect(result?.title == "Claude Code")
    #expect(result?.body == body)
  }

  @Test func doneAndErrorHaveFallbacks() {
    #expect(notification(ProgramStatusReport(state: .done, app: "codex"))?.body == "Finished")
    #expect(notification(ProgramStatusReport(state: .error, app: "codex"))?.body == "Stopped with an error")
  }

  @Test(arguments: [ProgramStatusReport.State.idle, .working, .clear])
  func quietStatesNeverNotify(_ state: ProgramStatusReport.State) {
    #expect(notification(ProgramStatusReport(state: state, app: "codex")) == nil)
  }

  @Test(arguments: [ProgramStatusReport.State.done, .blocked, .error])
  func repeatingAStateNeverNotifies(_ state: ProgramStatusReport.State) {
    #expect(notification(previous: state, ProgramStatusReport(state: state, app: "codex")) == nil)
  }

  @Test func childRecordsNeverNotify() {
    #expect(notification(ProgramStatusReport(state: .done, id: "child", app: "codex")) == nil)
  }

  @Test func titlePrefersTheReportThenTheAgentThenTheApp() {
    #expect(notification(ProgramStatusReport(state: .done, app: "codex", title: "Fix CI"))?.title == "Fix CI")
    #expect(notification(ProgramStatusReport(state: .done, app: "codex"))?.title == "Codex")
    #expect(notification(ProgramStatusReport(state: .done, app: "cargo"))?.title == "cargo")
    #expect(notification(ProgramStatusReport(state: .done))?.title == "")
  }

  @Test func textIsSanitizedAndBounded() {
    let long = String(repeating: "x", count: 1500)
    let result = notification(ProgramStatusReport(state: .done, app: "pi", title: "a\nb", message: long))

    #expect(result?.title == "a b")
    #expect(result?.body.count == 1000)
  }

  @Test func whitespaceOnlyMessageFallsBack() {
    #expect(notification(ProgramStatusReport(state: .done, app: "pi", message: "   "))?.body == "Finished")
  }
}
