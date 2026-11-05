import ComposableArchitecture
import Darwin
import Foundation
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct AgentPresenceProgramStatusTests {
  typealias Feature = AgentPresenceFeature

  private func report(
    _ state: ProgramStatusReport.State,
    app: String? = "claude-code",
    id: String = "",
    kind: ProgramStatusReport.Kind? = nil
  ) -> ProgramStatusReport {
    ProgramStatusReport(state: state, id: id, kind: kind, app: app)
  }

  private func key(_ agent: SkillAgent, _ surfaceID: UUID) -> Feature.PresenceKey {
    Feature.PresenceKey(agent: agent, surfaceID: surfaceID)
  }

  // MARK: - Root reports.

  @Test func rootReportSeedsAPidlessProgramStatusBadge() {
    var harness = Harness()
    let surfaceID = UUID()

    harness.send(.programStatusReceived(surfaceID: surfaceID, report: report(.working)))

    #expect(harness.state.agents(forSurface: surfaceID, badgesEnabled: true) == [.claude])
    let record = harness.state.records[key(.claude, surfaceID)]
    #expect(record?.activity == .busy)
    #expect(record?.pids.isEmpty == true)
    #expect(record?.source == .programStatus)
    #expect(harness.state.hasActivity(in: [surfaceID]))
  }

  @Test(arguments: [
    ("claude-code", SkillAgent.claude), ("codex", .codex), ("omp", .omp), ("opencode", .opencode), ("pi", .pi),
  ])
  func appPicksTheBadge(_ app: String, _ agent: SkillAgent) {
    var harness = Harness()
    let surfaceID = UUID()

    harness.send(.programStatusReceived(surfaceID: surfaceID, report: report(.idle, app: app)))

    #expect(harness.state.agents(forSurface: surfaceID, badgesEnabled: true) == [agent])
  }

  @Test(arguments: [
    (ProgramStatusReport.State.idle, Feature.Activity.idle),
    (.done, .idle),
    (.working, .busy),
    (.blocked, .awaitingInput),
    (.error, .error),
  ])
  func stateMapsToActivity(_ state: ProgramStatusReport.State, _ activity: Feature.Activity) {
    var harness = Harness()
    let surfaceID = UUID()

    harness.send(.programStatusReceived(surfaceID: surfaceID, report: report(state)))

    #expect(harness.state.records[key(.claude, surfaceID)]?.activity == activity)
  }

  @Test func idleReportSeedsARecordUnlikeAPidlessHookIdle() {
    // A program reports idle first when it starts, so idle must light the badge.
    var harness = Harness()
    let surfaceID = UUID()

    harness.send(.programStatusReceived(surfaceID: surfaceID, report: report(.idle)))

    #expect(harness.state.bySurface[surfaceID] == [.claude])
    #expect(!harness.state.hasActivity(in: [surfaceID]))
  }

  @Test func blockedIsAttentionAndErrorIsAnError() {
    var harness = Harness()
    let blocked = UUID()
    let errored = UUID()

    harness.send(.programStatusReceived(surfaceID: blocked, report: report(.blocked, kind: .question)))
    harness.send(.programStatusReceived(surfaceID: errored, report: report(.error)))

    #expect(harness.state.agents(across: [blocked], badgesEnabled: true).first?.awaitingInput == true)
    #expect(!harness.state.hasActivity(in: [blocked]))
    #expect(harness.state.hasError(in: [errored]))
    #expect(harness.state.rowSnapshot(across: [errored], badgesEnabled: true).hasError)
  }

  @Test func eachReportReplacesTheStateEvenAfterAnError() {
    // Unlike the hook lifecycle, a report is authoritative: no sticky error.
    var harness = Harness()
    let surfaceID = UUID()
    harness.send(.programStatusReceived(surfaceID: surfaceID, report: report(.error)))

    harness.send(.programStatusReceived(surfaceID: surfaceID, report: report(.idle)))

    #expect(harness.state.records[key(.claude, surfaceID)]?.activity == .idle)
    #expect(!harness.state.hasError(in: [surfaceID]))
  }

  @Test func walksAFullTurn() {
    var harness = Harness()
    let surfaceID = UUID()
    let turn: [(ProgramStatusReport.State, Feature.Activity)] = [
      (.idle, .idle), (.working, .busy), (.blocked, .awaitingInput), (.working, .busy), (.done, .idle),
    ]

    for (state, activity) in turn {
      harness.send(.programStatusReceived(surfaceID: surfaceID, report: report(state)))
      #expect(harness.state.records[key(.claude, surfaceID)]?.activity == activity)
    }
  }

  @Test(arguments: [nil, "cargo", "claude"])
  func reportWithoutAKnownAppIsIgnored(_ app: String?) {
    var harness = Harness()
    let surfaceID = UUID()

    harness.send(.programStatusReceived(surfaceID: surfaceID, report: report(.working, app: app)))

    #expect(harness.state.records.isEmpty)
    #expect(harness.state.bySurface.isEmpty)
  }

  @Test func childRecordsCarryNoBadge() {
    var harness = Harness()
    let surfaceID = UUID()

    harness.send(.programStatusReceived(surfaceID: surfaceID, report: report(.working, id: "subagent/1")))
    #expect(harness.state.records.isEmpty)

    harness.send(.programStatusReceived(surfaceID: surfaceID, report: report(.idle)))
    harness.send(.programStatusReceived(surfaceID: surfaceID, report: report(.blocked, id: "subagent/1")))
    #expect(harness.state.records[key(.claude, surfaceID)]?.activity == .idle)
  }

  @Test func twoAgentsOnOneSurfaceKeepSeparateBadges() {
    var harness = Harness()
    let surfaceID = UUID()

    harness.send(.programStatusReceived(surfaceID: surfaceID, report: report(.working)))
    harness.send(.programStatusReceived(surfaceID: surfaceID, report: report(.blocked, app: "codex")))

    #expect(harness.state.bySurface[surfaceID] == [.claude, .codex])
    #expect(harness.state.records[key(.claude, surfaceID)]?.activity == .busy)
    #expect(harness.state.records[key(.codex, surfaceID)]?.activity == .awaitingInput)
  }

  @Test func reportKeepsTheHookPidsOfAnExistingRecord() {
    // Before the migration removes the hooks, both channels can feed one agent.
    var harness = Harness()
    let surfaceID = UUID()
    let pid = getpid()
    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: pid)))

    harness.send(.programStatusReceived(surfaceID: surfaceID, report: report(.working)))

    let record = harness.state.records[key(.claude, surfaceID)]
    #expect(record?.pids == [pid])
    #expect(record?.source == .programStatus)
    #expect(record?.activity == .busy)
  }

  // MARK: - clear.

  @Test func rootClearRemovesTheBadge() {
    var harness = Harness()
    let surfaceID = UUID()
    harness.send(.programStatusReceived(surfaceID: surfaceID, report: report(.idle)))

    harness.send(.programStatusReceived(surfaceID: surfaceID, report: report(.clear, app: nil)))

    #expect(harness.state.records.isEmpty)
    #expect(harness.state.bySurface[surfaceID] == nil)
  }

  @Test func rootClearRemovesEveryProgramStatusRecordButKeepsHookRecords() {
    var harness = Harness()
    let surfaceID = UUID()
    harness.send(.programStatusReceived(surfaceID: surfaceID, report: report(.working)))
    harness.send(.programStatusReceived(surfaceID: surfaceID, report: report(.idle, app: "codex")))
    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .copilot, surfaceID: surfaceID, pid: getpid())))

    harness.send(.programStatusReceived(surfaceID: surfaceID, report: report(.clear, app: nil)))

    #expect(harness.state.bySurface[surfaceID] == [.copilot])
  }

  @Test func rootClearOnlyTouchesItsOwnSurface() {
    var harness = Harness()
    let cleared = UUID()
    let other = UUID()
    harness.send(.programStatusReceived(surfaceID: cleared, report: report(.idle)))
    harness.send(.programStatusReceived(surfaceID: other, report: report(.idle)))

    harness.send(.programStatusReceived(surfaceID: cleared, report: report(.clear, app: nil)))

    #expect(harness.state.bySurface[cleared] == nil)
    #expect(harness.state.bySurface[other] == [.claude])
  }

  @Test func childClearLeavesTheRootBadge() {
    var harness = Harness()
    let surfaceID = UUID()
    harness.send(.programStatusReceived(surfaceID: surfaceID, report: report(.working)))

    harness.send(.programStatusReceived(surfaceID: surfaceID, report: report(.clear, app: nil, id: "subagent")))

    #expect(harness.state.records[key(.claude, surfaceID)]?.activity == .busy)
  }

  // MARK: - Returning prompt.

  @Test(arguments: [ProgramStatusReport.State.working, .blocked])
  func returningPromptEndsWorkingAndBlocked(_ state: ProgramStatusReport.State) {
    var harness = Harness()
    let surfaceID = UUID()
    harness.send(.programStatusReceived(surfaceID: surfaceID, report: report(state)))

    harness.send(.programStatusPromptReturned(surfaceID: surfaceID))

    #expect(harness.state.records.isEmpty)
    #expect(harness.state.bySurface[surfaceID] == nil)
  }

  @Test(arguments: [ProgramStatusReport.State.idle, .done, .error])
  func returningPromptKeepsIdleDoneAndError(_ state: ProgramStatusReport.State) {
    var harness = Harness()
    let surfaceID = UUID()
    harness.send(.programStatusReceived(surfaceID: surfaceID, report: report(state)))
    let before = harness.state

    harness.send(.programStatusPromptReturned(surfaceID: surfaceID))

    #expect(harness.state == before)
  }

  @Test func returningPromptIgnoresHookRecords() {
    var harness = Harness()
    let surfaceID = UUID()
    harness.send(.hookEventReceived(makeEvent(.busy, agent: .copilot, surfaceID: surfaceID)))
    let before = harness.state

    harness.send(.programStatusPromptReturned(surfaceID: surfaceID))

    #expect(harness.state == before)
  }

  @Test func returningPromptDropsARecordWithHookPidsToIdle() {
    var harness = Harness()
    let surfaceID = UUID()
    let pid = getpid()
    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: pid)))
    harness.send(.programStatusReceived(surfaceID: surfaceID, report: report(.working)))

    harness.send(.programStatusPromptReturned(surfaceID: surfaceID))

    let record = harness.state.records[key(.claude, surfaceID)]
    #expect(record?.activity == .idle)
    #expect(record?.pids == [pid])
  }

  @Test func returningPromptOnlyTouchesItsOwnSurface() {
    var harness = Harness()
    let prompt = UUID()
    let other = UUID()
    harness.send(.programStatusReceived(surfaceID: prompt, report: report(.working)))
    harness.send(.programStatusReceived(surfaceID: other, report: report(.working)))

    harness.send(.programStatusPromptReturned(surfaceID: prompt))

    #expect(harness.state.bySurface[prompt] == nil)
    #expect(harness.state.records[key(.claude, other)]?.activity == .busy)
  }

  // MARK: - Shared lifecycle.

  @Test func focusingTheSurfaceAnswersABlockedRecord() {
    var harness = Harness()
    let surfaceID = UUID()
    harness.send(.programStatusReceived(surfaceID: surfaceID, report: report(.blocked, kind: .permission)))

    harness.send(.clearAttention(surfaces: [surfaceID]))

    #expect(harness.state.records[key(.claude, surfaceID)]?.activity == .idle)
  }

  @Test func closingTheSurfaceDropsTheRecord() {
    var harness = Harness()
    let surfaceID = UUID()
    harness.send(.programStatusReceived(surfaceID: surfaceID, report: report(.working)))

    harness.send(.surfaceClosed(surfaceID))

    #expect(harness.state.records.isEmpty)
    #expect(harness.state.bySurface.isEmpty)
  }

  @Test func livenessSweepNeverTouchesAPidlessProgramStatusRecord() {
    var harness = Harness()
    let surfaceID = UUID()
    harness.send(.programStatusReceived(surfaceID: surfaceID, report: report(.working)))

    let snapshot = harness.state.records.compactMapValues { $0.pids.isEmpty ? nil : $0.pids }

    #expect(snapshot.isEmpty)
  }

  // MARK: - Delegate fan-out.

  @Test func changesNotifyTheParentAndRepeatsDoNot() async {
    let surfaceID = UUID()
    let claude = key(.claude, surfaceID)
    let store = TestStore(initialState: Feature.State()) { Feature() }

    await store.send(.programStatusReceived(surfaceID: surfaceID, report: report(.working))) {
      $0.records[claude] = Feature.PresenceRecord(activity: .busy, pids: [], source: .programStatus)
      $0.bySurface[surfaceID] = [.claude]
    }
    await store.receive(\.delegate, .surfacesChanged([surfaceID]))

    // A repeat, a child record, and signals for other surfaces change nothing.
    await store.send(.programStatusReceived(surfaceID: surfaceID, report: report(.working)))
    await store.send(.programStatusReceived(surfaceID: surfaceID, report: report(.working, id: "child")))
    await store.send(.programStatusPromptReturned(surfaceID: UUID()))
    await store.send(.programStatusReceived(surfaceID: UUID(), report: report(.clear, app: nil)))

    await store.send(.programStatusReceived(surfaceID: surfaceID, report: report(.blocked))) {
      $0.records[claude]?.activity = .awaitingInput
    }
    await store.receive(\.delegate, .surfacesChanged([surfaceID]))

    await store.send(.programStatusPromptReturned(surfaceID: surfaceID)) {
      $0.records = [:]
      $0.bySurface = [:]
    }
    await store.receive(\.delegate, .surfacesChanged([surfaceID]))
  }

  // MARK: - Persistence.

  @Test func persistedRecordsMarkTheirSource() {
    var harness = Harness()
    let surfaceID = UUID()
    let pid = getpid()
    harness.send(.programStatusReceived(surfaceID: surfaceID, report: report(.working)))
    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .copilot, surfaceID: surfaceID, pid: pid)))

    let persisted = harness.state.agentsBySurface()[surfaceID]

    #expect(
      persisted == [
        .init(agent: "claude", pids: [], activity: "busy", source: "program_status"),
        .init(agent: "copilot", pids: [pid], activity: "idle", source: nil),
      ]
    )
  }

  @Test func agentRecordJSONStaysCompatible() throws {
    let legacy = Data(#"{"agent":"claude","pids":[42],"activity":"busy"}"#.utf8)
    let decoded = try JSONDecoder().decode(TerminalLayoutSnapshot.SurfaceAgentRecord.self, from: legacy)
    #expect(decoded == .init(agent: "claude", pids: [42], activity: "busy"))

    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let hook = try encoder.encode(decoded)
    #expect(String(bytes: hook, encoding: .utf8) == #"{"activity":"busy","agent":"claude","pids":[42]}"#)

    let program = TerminalLayoutSnapshot.SurfaceAgentRecord(
      agent: "codex", pids: [], activity: "idle", source: "program_status")
    let roundTripped = try JSONDecoder().decode(
      TerminalLayoutSnapshot.SurfaceAgentRecord.self, from: encoder.encode(program))
    #expect(roundTripped == program)
  }

  @Test func stagedRestoreKeepsProgramStatusRecordsAndSettlesTransientStates() {
    let busy = UUID()
    let blocked = UUID()
    let errored = UUID()
    let layout = makeLayout(surfaces: [
      (busy, [.init(agent: "claude", pids: [], activity: "busy", source: "program_status")]),
      (blocked, [.init(agent: "codex", pids: [], activity: "awaitingInput", source: "program_status")]),
      (errored, [.init(agent: "pi", pids: [], activity: "error", source: "program_status")]),
    ])

    let staged = Feature.stageRestore(fromLayouts: [layout])

    #expect(staged[key(.claude, busy)]?.activity == .idle)
    #expect(staged[key(.codex, blocked)]?.activity == .idle)
    #expect(staged[key(.pi, errored)]?.activity == .error)
    #expect(staged.values.allSatisfy { $0.source == .programStatus })
  }

  @Test func stagedRestoreStillDropsPidlessHookRecords() {
    let surfaceID = UUID()
    let layout = makeLayout(surfaces: [(surfaceID, [.init(agent: "claude", pids: [], activity: "busy")])])

    #expect(Feature.stageRestore(fromLayouts: [layout]).isEmpty)
  }

  @Test func checkRestoreKeepsProgramStatusOnlyForLiveSessions() {
    let alive = UUID()
    let gone = UUID()
    let staged: [Feature.PresenceKey: Feature.StagedRestore] = [
      key(.claude, alive): .init(pids: [], activity: .idle, source: .programStatus),
      key(.claude, gone): .init(pids: [], activity: .idle, source: .programStatus),
    ]

    let checked = Feature.checkRestore(staged: staged, liveSessions: [ZmxSessionID.make(surfaceID: alive)])

    #expect(Set(checked.keys) == [key(.claude, alive)])
    #expect(checked[key(.claude, alive)]?.source == .programStatus)
    #expect(checked[key(.claude, alive)]?.alivePids.isEmpty == true)
  }

  @Test func checkRestoreStillProbesHookPids() {
    let surfaceID = UUID()
    let staged: [Feature.PresenceKey: Feature.StagedRestore] = [
      key(.copilot, surfaceID): .init(pids: [getpid()], activity: .busy)
    ]

    let checked = Feature.checkRestore(staged: staged, liveSessions: [])

    #expect(checked[key(.copilot, surfaceID)]?.alivePids == [getpid()])
    #expect(checked[key(.copilot, surfaceID)]?.source == .hook)
  }

  @Test func restoreAsksZmxWhichSessionsSurvived() async {
    let alive = UUID()
    let gone = UUID()
    let staged: [Feature.PresenceKey: Feature.StagedRestore] = [
      key(.claude, alive): .init(pids: [], activity: .idle, source: .programStatus),
      key(.codex, gone): .init(pids: [], activity: .error, source: .programStatus),
    ]
    let store = TestStore(initialState: Feature.State()) {
      Feature()
    } withDependencies: {
      $0.zmxClient.listSessionsWithClients = {
        [ZmxSessionListParser.Entry(name: ZmxSessionID.make(surfaceID: alive), clients: 0)]
      }
    }
    store.exhaustivity = .off

    await store.send(.restoreFromSnapshot(staged: staged))
    await store.receive(\.restoreFromSnapshotChecked)
    await store.receive(\.delegate, .surfacesChanged([alive]))

    #expect(store.state.bySurface == [alive: [.claude]])
    #expect(store.state.records[key(.claude, alive)]?.source == .programStatus)
  }

  @Test func restoreDropsProgramStatusWhenZmxCannotSay() async {
    let surfaceID = UUID()
    let staged: [Feature.PresenceKey: Feature.StagedRestore] = [
      key(.claude, surfaceID): .init(pids: [], activity: .idle, source: .programStatus)
    ]
    let store = TestStore(initialState: Feature.State()) {
      Feature()
    } withDependencies: {
      $0.zmxClient.listSessionsWithClients = { nil }
    }

    await store.send(.restoreFromSnapshot(staged: staged))
    await store.finish()

    #expect(store.state.records.isEmpty)
  }

  @Test func restoredRecordNeverClobbersALiveReport() {
    var harness = Harness()
    let surfaceID = UUID()
    harness.send(.programStatusReceived(surfaceID: surfaceID, report: report(.working)))

    harness.send(
      .restoreFromSnapshotChecked(records: [
        key(.claude, surfaceID): .init(alivePids: [], activity: .idle, source: .programStatus)
      ]))

    #expect(harness.state.records[key(.claude, surfaceID)]?.activity == .busy)
  }

  // MARK: - Helpers.

  private struct Harness {
    var state = Feature.State()
    private let reducer = Feature()

    @MainActor mutating func send(_ action: Feature.Action) {
      _ = reducer.reduce(into: &state, action: action)
    }
  }

  private func makeLayout(
    surfaces: [(id: UUID, agents: [TerminalLayoutSnapshot.SurfaceAgentRecord])]
  ) -> TerminalLayoutSnapshot {
    let tabs = surfaces.map { surface in
      TerminalLayoutSnapshot.TabSnapshot(
        id: UUID(),
        title: "tab",
        customTitle: nil,
        icon: nil,
        tintColor: nil,
        layout: .leaf(
          TerminalLayoutSnapshot.SurfaceSnapshot(id: surface.id, workingDirectory: nil, agents: surface.agents)),
        focusedLeafIndex: 0
      )
    }
    return TerminalLayoutSnapshot(tabs: tabs, selectedTabIndex: 0)
  }

  private func makeEvent(
    _ name: AgentHookEvent.EventName, agent: SkillAgent, surfaceID: UUID, pid: pid_t? = nil
  ) -> AgentHookEvent {
    let pidLine = pid.map { #","pid":\#($0)"# } ?? ""
    let json =
      #"{"event":"\#(name.rawValue)","agent":"\#(agent.rawValue)","surface_id":"\#(surfaceID.uuidString)"\#(pidLine)}"#
    guard let event = try? JSONDecoder().decode(AgentHookEvent.self, from: Data(json.utf8)) else {
      preconditionFailure("Failed to parse test event")
    }
    return event
  }
}
