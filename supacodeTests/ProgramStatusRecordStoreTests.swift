import Testing

@testable import supacode

struct ProgramStatusRecordStoreTests {
  private func report(
    _ state: ProgramStatusReport.State,
    id: String = "",
    app: String? = nil,
    kind: ProgramStatusReport.Kind? = nil
  ) -> ProgramStatusEvent {
    .report(ProgramStatusReport(id: id, state: state, kind: kind, app: app))
  }

  private func store(_ events: ProgramStatusEvent...) -> ProgramStatusRecordStore {
    var store = ProgramStatusRecordStore()
    for event in events { store.apply(event) }
    return store
  }

  @Test func aReportReplacesItsWholeRecord() {
    let store = store(
      .report(ProgramStatusReport(id: "", state: .working, progress: 40, app: "cargo", message: "build")),
      report(.idle)
    )

    #expect(store.records[""]?.report == ProgramStatusReport(id: "", state: .idle))
    #expect(store.summary == .init(app: nil, state: .idle))
  }

  @Test func clearRemovesTheRecordAndItsChildrenOnly() {
    let store = store(
      report(.working, id: "deploy"),
      report(.blocked, id: "deploy/us-east"),
      report(.working, id: "deployment"),
      report(.idle, app: "rex"),
      .clear(id: "deploy")
    )

    #expect(Set(store.records.keys) == ["", "deployment"])
  }

  @Test func clearingTheRootRemovesEveryRecord() {
    let store = store(report(.working, id: "a"), report(.idle), .clear(id: ""))

    #expect(store.records.isEmpty)
  }

  @Test func appComesFromTheNearestAncestorThenTheRoot() {
    let store = store(
      report(.working, app: "claude-code"),
      report(.working, id: "build", app: "cargo"),
      report(.working, id: "build/test/unit"),
      report(.working, id: "lint")
    )

    let unit = store.records["build/test/unit"]!.report
    let lint = store.records["lint"]!.report
    #expect(store.effectiveApp(of: unit) == "cargo")
    #expect(store.effectiveApp(of: lint) == "claude-code")
  }

  @Test func theLeastRecentlyUpdatedRecordIsEvictedPastCapacity() {
    var store = ProgramStatusRecordStore()
    for index in 0..<ProgramStatusRecordStore.capacity {
      store.apply(report(.working, id: "r\(index)"))
    }
    store.apply(report(.done, id: "r0"))
    store.apply(report(.working, id: "overflow"))

    #expect(store.records.count == ProgramStatusRecordStore.capacity)
    #expect(store.records["r0"] != nil)
    #expect(store.records["r1"] == nil)
    #expect(store.records["overflow"] != nil)
  }

  @Test func theShellsPromptAfterTheReporterExitsDropsItsTransientRecords() {
    let store = store(
      .promptStart,
      .commandStart,
      report(.working, app: "claude-code"),
      report(.blocked, id: "task", kind: .permission),
      report(.idle, id: "idler"),
      report(.done, id: "result"),
      report(.error, id: "failure"),
      .commandEnd,
      .promptStart
    )

    #expect(Set(store.records.keys) == ["result", "failure"])
  }

  @Test func anAgentsOwnMarksInsideTheCommandKeepItsRecords() {
    let store = store(
      .commandStart,
      report(.working, app: "omp"),
      .promptStart,
      .commandStart,
      .commandEnd,
      .promptStart
    )

    #expect(store.summary.state == .working)
  }

  @Test func aRefreshInsideTheAgentsOwnCommandKeepsTheOuterLifetime() {
    let store = store(
      .commandStart,
      report(.working, app: "omp"),
      .commandStart,
      report(.blocked, kind: .permission),
      .commandEnd,
      .promptStart
    )

    var exited = store
    exited.apply(.commandEnd)
    exited.apply(.promptStart)

    #expect(store.summary.state == .blocked)
    #expect(exited.records.isEmpty)
  }

  @Test func aReportAfterADoneRecordStartsANewLifetime() {
    let store = store(
      report(.done, id: "build"),
      .commandStart,
      .commandStart,
      report(.working, id: "build"),
      .commandEnd,
      .promptStart
    )

    #expect(store.records.isEmpty)
  }

  @Test func withoutShellIntegrationAPromptNeverDropsALiveRecord() {
    let store = store(report(.working, app: "codex"), .promptStart, .commandStart, .commandEnd, .promptStart)

    #expect(store.summary.state == .working)
  }

  @Test func strayCommandEndsBeforeTheCommandStillLetTheExitDrop() {
    let store = store(
      .commandEnd,
      .commandEnd,
      .promptStart,
      .commandStart,
      report(.working, app: "claude-code"),
      .commandEnd,
      .commandEnd,
      .promptStart
    )

    #expect(store.records.isEmpty)
  }

  @Test func aSuccessorsReportSurvivesThePredecessorsExit() {
    let store = store(
      .commandStart,
      report(.working, id: "old"),
      .commandEnd,
      .promptStart,
      .commandStart,
      report(.working, id: "new"),
      .promptStart
    )

    #expect(Set(store.records.keys) == ["new"])
  }

  @Test func theSummaryReadsTheRootAndFlagsBusyChildren() {
    let store = store(
      report(.blocked, app: "claude-code", kind: .question),
      report(.working, id: "agent-1"),
      report(.blocked, id: "agent-2")
    )

    #expect(
      store.summary
        == .init(app: "claude-code", state: .blocked, kind: .question, hasWorkingChild: true, hasBlockedChild: true)
    )
    #expect(store.summary.description == "app=claude-code state=blocked kind=question workingChild blockedChild")
  }
}
