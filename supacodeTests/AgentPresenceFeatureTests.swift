import ComposableArchitecture
import Darwin
import Dependencies
import Foundation
import Sharing
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct AgentPresenceFeatureTests {
  // MARK: - Session lifecycle.

  @Test func sessionStartRegistersAgentForSurface() {
    var harness = Harness()
    let surfaceID = UUID()

    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: getpid())))

    #expect(harness.state.agents(forSurface: surfaceID, badgesEnabled: true) == Set([.claude]))
  }
  @Test func ompSessionStartRegistersAgentForSurface() {
    var harness = Harness()
    let surfaceID = UUID()
    let pid = getpid()

    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .omp, surfaceID: surfaceID, pid: pid)))

    #expect(harness.state.agents(forSurface: surfaceID, badgesEnabled: true) == Set([.omp]))
    let key = AgentPresenceFeature.PresenceKey(agent: .omp, surfaceID: surfaceID)
    #expect(harness.state.records[key]?.pids == [pid])
  }
  @Test func grokSessionStartRegistersAgentForSurface() {
    var harness = Harness()
    let surfaceID = UUID()
    let pid = getpid()

    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .grok, surfaceID: surfaceID, pid: pid)))

    #expect(harness.state.agents(forSurface: surfaceID, badgesEnabled: true) == Set([.grok]))
    let key = AgentPresenceFeature.PresenceKey(agent: .grok, surfaceID: surfaceID)
    #expect(harness.state.records[key]?.pids == [pid])
  }

  @Test func sessionStartWithoutPidSeedsPidlessRecord() {
    // The OSC-over-SSH transport attributes by the receiving surface and has no
    // remote pid, so a pid-less session_start is a valid signal: it seeds a
    // record so the badge lights at launch. The record carries no pid, so the
    // kill(2) sweep skips it; teardown is via session_end or surface close.
    var harness = Harness()
    let surfaceID = UUID()

    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID)))

    #expect(harness.state.agents(forSurface: surfaceID, badgesEnabled: true) == Set([.claude]))
    let key = AgentPresenceFeature.PresenceKey(agent: .claude, surfaceID: surfaceID)
    #expect(harness.state.records[key]?.pids.isEmpty == true)
  }

  // MARK: - Error + compaction.

  @Test func errorMarksSurfaceErroredAndHasErrorReportsIt() {
    var harness = Harness()
    let surfaceID = UUID()
    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: getpid())))

    harness.send(.hookEventReceived(makeEvent(.error, agent: .claude, surfaceID: surfaceID, pid: getpid())))

    let key = AgentPresenceFeature.PresenceKey(agent: .claude, surfaceID: surfaceID)
    #expect(harness.state.records[key]?.activity == .error)
    #expect(harness.state.hasError(in: [surfaceID]))
    // The turn is dead, so it must not drive the shimmer.
    #expect(!harness.state.hasActivity(in: [surfaceID]))
  }

  @Test func busyClearsStickyError() {
    var harness = Harness()
    let surfaceID = UUID()
    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: getpid())))
    harness.send(.hookEventReceived(makeEvent(.error, agent: .claude, surfaceID: surfaceID, pid: getpid())))

    harness.send(.hookEventReceived(makeEvent(.busy, agent: .claude, surfaceID: surfaceID, pid: getpid())))

    #expect(!harness.state.hasError(in: [surfaceID]))
    #expect(harness.state.hasActivity(in: [surfaceID]))
  }

  @Test func awaitingInputAndIdleCannotDowngradeStickyError() {
    // Claude's 60s-idle Notification fires `awaiting_input` on exactly the session
    // that just died, so nothing but a new turn may leave the errored state.
    var harness = Harness()
    let surfaceID = UUID()
    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: getpid())))
    harness.send(.hookEventReceived(makeEvent(.error, agent: .claude, surfaceID: surfaceID, pid: getpid())))

    harness.send(.hookEventReceived(makeEvent(.awaitingInput, agent: .claude, surfaceID: surfaceID, pid: getpid())))
    #expect(harness.state.hasError(in: [surfaceID]))

    harness.send(.hookEventReceived(makeEvent(.idle, agent: .claude, surfaceID: surfaceID, pid: getpid())))
    #expect(harness.state.hasError(in: [surfaceID]))
  }

  @Test func sessionStartClearsStickyError() {
    var harness = Harness()
    let surfaceID = UUID()
    let pid = getpid()
    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: pid)))
    harness.send(.hookEventReceived(makeEvent(.error, agent: .claude, surfaceID: surfaceID, pid: pid)))

    // A restart re-fires session_start for the same (surface, pid).
    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: pid)))

    #expect(!harness.state.hasError(in: [surfaceID]))
  }

  @Test func pidlessSessionStartClearsStickyState() {
    // Over SSH the presence OSC carries no pid, so the restart must still clear a
    // sticky error and end a compaction that finished while we weren't looking.
    var harness = Harness()
    let surfaceID = UUID()
    harness.send(.hookEventReceived(makeEvent(.error, agent: .claude, surfaceID: surfaceID)))
    #expect(harness.state.hasError(in: [surfaceID]))

    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID)))
    #expect(!harness.state.hasError(in: [surfaceID]))

    harness.send(.hookEventReceived(makeEvent(.compacting, agent: .claude, surfaceID: surfaceID)))
    #expect(harness.state.isCompacting(in: [surfaceID]))

    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID)))
    #expect(!harness.state.isCompacting(in: [surfaceID]))
  }

  @Test func clearAttentionResetsErroredAndAwaitingSurfaces() {
    var harness = Harness()
    let errored = UUID()
    let awaiting = UUID()
    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: errored, pid: getpid())))
    harness.send(.hookEventReceived(makeEvent(.error, agent: .claude, surfaceID: errored, pid: getpid())))
    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: awaiting, pid: getpid())))
    harness.send(.hookEventReceived(makeEvent(.awaitingInput, agent: .claude, surfaceID: awaiting, pid: getpid())))

    harness.send(.clearAttention(surfaces: [errored, awaiting]))

    #expect(!harness.state.hasError(in: [errored]))
    #expect(harness.state.agents(across: [awaiting], badgesEnabled: true).first?.awaitingInput == false)
  }

  @Test func compactingCountsAsWorkAndIsClearedByTheNextEvent() {
    var harness = Harness()
    let surfaceID = UUID()
    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: getpid())))

    harness.send(.hookEventReceived(makeEvent(.compacting, agent: .claude, surfaceID: surfaceID, pid: getpid())))
    #expect(harness.state.isCompacting(in: [surfaceID]))
    #expect(!harness.state.hasError(in: [surfaceID]))
    // Compaction runs inside a turn, so the row must keep shimmering.
    #expect(harness.state.hasActivity(in: [surfaceID]))

    harness.send(.hookEventReceived(makeEvent(.busy, agent: .claude, surfaceID: surfaceID, pid: getpid())))
    #expect(!harness.state.isCompacting(in: [surfaceID]))

    harness.send(.hookEventReceived(makeEvent(.compacting, agent: .claude, surfaceID: surfaceID, pid: getpid())))
    harness.send(.hookEventReceived(makeEvent(.idle, agent: .claude, surfaceID: surfaceID, pid: getpid())))
    #expect(!harness.state.isCompacting(in: [surfaceID]))
  }

  @Test func rowSnapshotHidesErrorWhenBadgesAreDisabled() {
    // The badge carries the error treatment, so with badges off there is nothing
    // to surface and the row must not float to the top of Active either.
    var harness = Harness()
    let surfaceID = UUID()
    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: getpid())))
    harness.send(.hookEventReceived(makeEvent(.error, agent: .claude, surfaceID: surfaceID, pid: getpid())))

    #expect(harness.state.rowSnapshot(across: [surfaceID], badgesEnabled: true).hasError)
    #expect(!harness.state.rowSnapshot(across: [surfaceID], badgesEnabled: false).hasError)
  }

  @Test func awaitingInputWithoutPidLazilyCreatesAwaitingRecord() {
    // A remote agent's awaiting-input OSC arrives with no pid and possibly no
    // prior session_start; it must still light the badge.
    var harness = Harness()
    let surfaceID = UUID()

    harness.send(.hookEventReceived(makeEvent(.awaitingInput, agent: .claude, surfaceID: surfaceID)))

    let instances = harness.state.agents(across: [surfaceID], badgesEnabled: true)
    #expect(instances.count == 1)
    #expect(instances.first?.awaitingInput == true)
  }

  @Test func pidlessActivityIsIdempotent() {
    var harness = Harness()
    let surfaceID = UUID()

    harness.send(.hookEventReceived(makeEvent(.awaitingInput, agent: .claude, surfaceID: surfaceID)))
    harness.send(.hookEventReceived(makeEvent(.awaitingInput, agent: .claude, surfaceID: surfaceID)))

    #expect(harness.state.records.count == 1)
    #expect(harness.state.agents(across: [surfaceID], badgesEnabled: true).first?.awaitingInput == true)
  }

  @Test func pidlessSessionEndClearsOnlyPidlessRecord() {
    var harness = Harness()
    let pidlessSurface = UUID()
    let pidSurface = UUID()
    let pid = getpid()

    harness.send(.hookEventReceived(makeEvent(.awaitingInput, agent: .claude, surfaceID: pidlessSurface)))
    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: pidSurface, pid: pid)))

    // Pid-less session_end clears the pid-less (OSC-origin) record...
    harness.send(.hookEventReceived(makeEvent(.sessionEnd, agent: .claude, surfaceID: pidlessSurface)))
    #expect(harness.state.agents(forSurface: pidlessSurface, badgesEnabled: true).isEmpty)
    // ...but never a local pid-bearing record.
    harness.send(.hookEventReceived(makeEvent(.sessionEnd, agent: .claude, surfaceID: pidSurface)))
    #expect(harness.state.agents(forSurface: pidSurface, badgesEnabled: true) == Set([.claude]))
  }

  @Test func sessionEndRemovesAgentForSurface() {
    var harness = Harness()
    let surfaceID = UUID()
    let pid = getpid()

    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: pid)))
    harness.send(.hookEventReceived(makeEvent(.sessionEnd, agent: .claude, surfaceID: surfaceID, pid: pid)))

    #expect(harness.state.agents(forSurface: surfaceID, badgesEnabled: true).isEmpty)
  }
  @Test func ompSessionEndRemovesLocalPidRecord() {
    var harness = Harness()
    let surfaceID = UUID()
    let pid = getpid()

    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .omp, surfaceID: surfaceID, pid: pid)))
    harness.send(.hookEventReceived(makeEvent(.sessionEnd, agent: .omp, surfaceID: surfaceID, pid: pid)))

    #expect(harness.state.agents(forSurface: surfaceID, badgesEnabled: true).isEmpty)
    let key = AgentPresenceFeature.PresenceKey(agent: .omp, surfaceID: surfaceID)
    #expect(harness.state.records[key] == nil)
  }
  @Test func grokSessionEndRemovesLocalPidRecord() {
    var harness = Harness()
    let surfaceID = UUID()
    let pid = getpid()

    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .grok, surfaceID: surfaceID, pid: pid)))
    harness.send(.hookEventReceived(makeEvent(.sessionEnd, agent: .grok, surfaceID: surfaceID, pid: pid)))

    #expect(harness.state.agents(forSurface: surfaceID, badgesEnabled: true).isEmpty)
    let key = AgentPresenceFeature.PresenceKey(agent: .grok, surfaceID: surfaceID)
    #expect(harness.state.records[key] == nil)
  }

  @Test func sessionStartIsIdempotentForSameProcessPid() {
    // Reproduces Claude `/resume`: SessionStart fires on startup AND on
    // resume (one process, two events, same pid). One SessionEnd clears
    // the record. There's only one process to liveness-track.
    var harness = Harness()
    let surfaceID = UUID()
    let agentPid: pid_t = getpid()

    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: agentPid)))
    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: agentPid)))
    harness.send(.hookEventReceived(makeEvent(.sessionEnd, agent: .claude, surfaceID: surfaceID, pid: agentPid)))

    #expect(harness.state.agents(forSurface: surfaceID, badgesEnabled: true).isEmpty)
  }

  @Test func surfaceClosedClearsEntriesEvenWithoutSessionEnd() {
    var harness = Harness()
    let surfaceID = UUID()

    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: getpid())))
    #expect(harness.state.agents(forSurface: surfaceID, badgesEnabled: true) == Set([.claude]))

    harness.send(.surfaceClosed(surfaceID))

    #expect(harness.state.agents(forSurface: surfaceID, badgesEnabled: true).isEmpty)
  }

  @Test func surfaceClosedClearsAwaitingState() {
    // Closing a surface mid-awaiting-input clears the record so the sidebar /
    // tab badges drop to idle without waiting on the agent to fire idle
    // (which it can't: the user closed the tab).
    var harness = Harness()
    let surfaceID = UUID()

    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: getpid())))
    harness.send(.hookEventReceived(makeEvent(.awaitingInput, agent: .claude, surfaceID: surfaceID)))
    #expect(!harness.state.agents(forSurface: surfaceID, badgesEnabled: true).isEmpty)

    harness.send(.surfaceClosed(surfaceID))

    #expect(harness.state.hasActivity(in: [surfaceID]) == false)
    #expect(harness.state.agents(forSurface: surfaceID, badgesEnabled: true).isEmpty)
  }

  @Test func unknownAgentNameIsIgnored() {
    var harness = Harness()
    let surfaceID = UUID()
    let json = """
      {
        "event": "session_start",
        "agent": "imaginary-agent",
        "surface_id": "\(surfaceID.uuidString)"
      }
      """
    guard let parsed = try? JSONDecoder().decode(AgentHookEvent.self, from: Data(json.utf8)) else {
      Issue.record("Expected event")
      return
    }
    harness.send(.hookEventReceived(parsed))

    #expect(harness.state.agents(forSurface: surfaceID, badgesEnabled: true).isEmpty)
  }

  @Test func unknownEventNameIsIgnored() {
    var harness = Harness()
    let surfaceID = UUID()
    harness.send(
      .hookEventReceived(
        makeEvent(
          rawEventName: "future_event_we_dont_know",
          agent: .claude, surfaceID: surfaceID)))

    #expect(harness.state.agents(forSurface: surfaceID, badgesEnabled: true).isEmpty)
  }

  // MARK: - OSC (pid-less) presence.

  @Test func pidlessBusyWithoutSessionStartAutoSeeds() {
    // Over SSH the user may attach to a surface whose agent is already running,
    // so the first OSC seen is `busy`, not `session_start`. The pid-less path
    // must auto-seed a record so the badge lights regardless of arrival order.
    var harness = Harness()
    let surfaceID = UUID()

    harness.send(.hookEventReceived(makeEvent(.busy, agent: .claude, surfaceID: surfaceID)))

    let claude = harness.state.agents(across: [surfaceID], badgesEnabled: true).first { $0.agent == .claude }
    #expect(claude?.activity == .busy)
    #expect(harness.state.hasActivity(in: [surfaceID]) == true)
  }

  @Test func pidlessSessionEndRemovesPidlessRecord() {
    var harness = Harness()
    let surfaceID = UUID()

    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID)))
    harness.send(.hookEventReceived(makeEvent(.sessionEnd, agent: .claude, surfaceID: surfaceID)))

    #expect(harness.state.agents(forSurface: surfaceID, badgesEnabled: true).isEmpty)
  }

  @Test func pidlessRecordSurvivesSweepThatReapsCoLocatedDeadPid() {
    // A pid-less (OSC) record must survive the sweep even while a co-located dead
    // pid-bearing record is reaped: the sweep only targets records with pids.
    var harness = Harness()
    let surfaceID = UUID()
    let deadPid = makeDeadPid()

    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID)))
    harness.send(.hookEventReceived(makeEvent(.busy, agent: .claude, surfaceID: surfaceID)))
    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .codex, surfaceID: surfaceID, pid: deadPid)))

    harness.livenessSweep()

    #expect(harness.state.agents(forSurface: surfaceID, badgesEnabled: true) == Set([.claude]))
    let claudeKey = AgentPresenceFeature.PresenceKey(agent: .claude, surfaceID: surfaceID)
    #expect(harness.state.records[claudeKey]?.activity == .busy)
  }

  @Test func pidBearingActivityWithoutPresenceDoesNotSeed() {
    // Auto-seed is pid-less-only. A pid-bearing awaiting_input / idle
    // with no session_start must still be dropped, like busyWithoutPresenceIsDropped.
    var harness = Harness()
    let surfaceID = UUID()

    harness.send(.hookEventReceived(makeEvent(.awaitingInput, agent: .claude, surfaceID: surfaceID, pid: getpid())))
    harness.send(.hookEventReceived(makeEvent(.idle, agent: .codex, surfaceID: surfaceID, pid: getpid())))

    #expect(harness.state.agents(forSurface: surfaceID, badgesEnabled: true).isEmpty)
  }

  @Test func pidlessSessionEndTearsDownRegardlessOfActivity() {
    // Teardown keys on record.pids.isEmpty, not the activity flip: an OSC record
    // that went busy then idle must still be removed by session_end.
    var harness = Harness()
    let surfaceID = UUID()

    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID)))
    harness.send(.hookEventReceived(makeEvent(.busy, agent: .claude, surfaceID: surfaceID)))
    harness.send(.hookEventReceived(makeEvent(.idle, agent: .claude, surfaceID: surfaceID)))
    harness.send(.hookEventReceived(makeEvent(.sessionEnd, agent: .claude, surfaceID: surfaceID)))

    #expect(harness.state.agents(forSurface: surfaceID, badgesEnabled: true).isEmpty)
  }

  @Test func pidBearingRecordSurvivesPidlessSessionEnd() {
    // Pid-bearing wins: a pid-less (OSC over SSH) session_end must never tear
    // down a record that still carries a tracked local pid for the same
    // surface/agent.
    var harness = Harness()
    let surfaceID = UUID()
    let pid = getpid()

    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: pid)))
    harness.send(.hookEventReceived(makeEvent(.sessionEnd, agent: .claude, surfaceID: surfaceID)))

    #expect(harness.state.agents(forSurface: surfaceID, badgesEnabled: true) == Set([.claude]))
  }

  @Test func pidlessSessionStartDoesNotClobberPidBearingRecord() {
    // Pid-bearing wins on seed too: a pid-less OSC session_start arriving after
    // the local hook has registered a pid must not reset the record.
    var harness = Harness()
    let surfaceID = UUID()
    let pid = getpid()

    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: pid)))
    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID)))

    let key = AgentPresenceFeature.PresenceKey(agent: .claude, surfaceID: surfaceID)
    #expect(harness.state.records[key]?.pids == [pid])
  }

  @Test func pidlessSessionStartUpgradedByPidSessionStartCarriesPid() {
    // OSC pid-less arrives first (SSH attach), then the local hook lands with a
    // pid: the existing pid-less record must be upgraded in place so the sweep
    // can reap it.
    var harness = Harness()
    let surfaceID = UUID()
    let pid: pid_t = 1234

    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID)))
    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: pid)))

    let key = AgentPresenceFeature.PresenceKey(agent: .claude, surfaceID: surfaceID)
    #expect(harness.state.records[key]?.pids == [pid])
  }

  @Test func pidlessSessionEndFollowedByIdleDoesNotReseedRecord() {
    // Both Claude's SessionEnd hook and the Pi `session_shutdown` extension emit
    // a `session_end` + `idle` composite. After the pid-less session_end clears
    // the record, the debounced idle must NOT auto-seed a new pid-less record:
    // the sweep can never reap such a record (no pid to check) and no further
    // session_end follows, so the badge would stay until surface close.
    var harness = Harness()
    let surfaceID = UUID()

    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID)))
    harness.send(.hookEventReceived(makeEvent(.busy, agent: .claude, surfaceID: surfaceID)))
    harness.send(.hookEventReceived(makeEvent(.sessionEnd, agent: .claude, surfaceID: surfaceID)))
    harness.send(.hookEventReceived(makeEvent(.idle, agent: .claude, surfaceID: surfaceID)))

    #expect(harness.state.agents(forSurface: surfaceID, badgesEnabled: true).isEmpty)
    let key = AgentPresenceFeature.PresenceKey(agent: .claude, surfaceID: surfaceID)
    #expect(harness.state.records[key] == nil)
  }

  @Test func pidUpgradedRecordIsReapedByMatchingPidSessionEnd() {
    // Pid-less seed (SSH attach) followed by a pid-bearing session_start that
    // upgrades the record. The matching pid-bearing session_end must remove the
    // record entirely; otherwise the badge sticks once the pid set goes empty.
    var harness = Harness()
    let surfaceID = UUID()
    let pid: pid_t = 1234

    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID)))
    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: pid)))
    harness.send(.hookEventReceived(makeEvent(.sessionEnd, agent: .claude, surfaceID: surfaceID, pid: pid)))

    #expect(harness.state.agents(forSurface: surfaceID, badgesEnabled: true).isEmpty)
    let key = AgentPresenceFeature.PresenceKey(agent: .claude, surfaceID: surfaceID)
    #expect(harness.state.records[key] == nil)
  }

  // MARK: - Liveness.

  @Test func livenessSweepEvictsRecordsForDeadPid() {
    var harness = Harness()
    let surfaceID = UUID()
    // Use the test process's own pid: guaranteed alive, and unlike pid 1
    // (launchd) it isn't signal-protected so `kill(pid, 0)` returns 0.
    let alivePid: pid_t = getpid()
    let deadPid = makeDeadPid()

    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: alivePid)))
    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .codex, surfaceID: surfaceID, pid: deadPid)))

    #expect(harness.state.agents(forSurface: surfaceID, badgesEnabled: true) == Set([.claude, .codex]))

    harness.livenessSweep()

    // Codex's pid is dead → record evicted. Claude's pid is alive → kept.
    #expect(harness.state.agents(forSurface: surfaceID, badgesEnabled: true) == Set([.claude]))
  }

  @Test func livenessSweepEvictingAwaitingRecordClearsBadgeImmediately() {
    // A Claude process that crashes mid-awaiting-input would leave a sticky
    // orange badge until the user closed the surface. The pid sweep must drop
    // the awaiting record entirely, not just downgrade it.
    var harness = Harness()
    let surfaceID = UUID()
    let deadPid = makeDeadPid()

    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: deadPid)))
    harness.send(.hookEventReceived(makeEvent(.awaitingInput, agent: .claude, surfaceID: surfaceID)))
    #expect(!harness.state.agents(forSurface: surfaceID, badgesEnabled: true).isEmpty)

    harness.livenessSweep()

    #expect(harness.state.agents(forSurface: surfaceID, badgesEnabled: true).isEmpty)
    #expect(harness.state.hasActivity(in: [surfaceID]) == false)
  }

  @Test func livenessSweepHonorsSessionEndDuringHop() {
    // A `.sessionEnd` for a pid that was alive at snapshot capture but landed
    // during the off-main hop must not be resurrected by the apply step.
    var harness = Harness()
    let surfaceID = UUID()
    let deadPid = makeDeadPid()
    let endingPid: pid_t = getpid()

    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: deadPid)))
    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: endingPid)))

    let key = AgentPresenceFeature.PresenceKey(agent: .claude, surfaceID: surfaceID)
    let snapshot: [AgentPresenceFeature.PresenceKey: Set<pid_t>] = [key: [deadPid, endingPid]]
    let alive = AgentPresenceFeature.liveness(forSnapshot: snapshot)

    harness.send(.hookEventReceived(makeEvent(.sessionEnd, agent: .claude, surfaceID: surfaceID, pid: endingPid)))

    harness.send(.livenessSweepResult(snapshot: snapshot, alive: alive))

    #expect(harness.state.records[key] == nil)
    #expect(harness.state.agents(forSurface: surfaceID, badgesEnabled: true).isEmpty)
  }

  @Test func livenessSweepPreservesPidsAddedAfterSnapshot() {
    // A `.sessionStart` that lands between the off-main `liveness` snapshot
    // and the `applyLiveness` hop must not be evicted. Simulated by computing
    // the alive delta against an older snapshot, then dispatching the result
    // after a new pid has been inserted.
    var harness = Harness()
    let surfaceID = UUID()
    let deadPid = makeDeadPid()
    let lateAlivePid: pid_t = getpid()

    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: deadPid)))

    let key = AgentPresenceFeature.PresenceKey(agent: .claude, surfaceID: surfaceID)
    let snapshot: [AgentPresenceFeature.PresenceKey: Set<pid_t>] = [key: [deadPid]]
    let alive = AgentPresenceFeature.liveness(forSnapshot: snapshot)

    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: lateAlivePid)))

    harness.send(.livenessSweepResult(snapshot: snapshot, alive: alive))

    #expect(harness.state.agents(forSurface: surfaceID, badgesEnabled: true) == Set([.claude]))
    #expect(harness.state.records[key]?.pids == [lateAlivePid])
  }

  @Test func livenessSweepPartialPidEvictionPreservesActivity() {
    // When only some of a multi-pid record's pids die (e.g. Claude crash +
    // reopen in the same surface, where SessionStart for the new pid
    // union-inserts), the surviving record's activity must NOT be wiped to .idle.
    var harness = Harness()
    let surfaceID = UUID()
    let alivePid: pid_t = getpid()
    let deadPid = makeDeadPid()

    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: deadPid)))
    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: alivePid)))
    harness.send(.hookEventReceived(makeEvent(.awaitingInput, agent: .claude, surfaceID: surfaceID)))

    let beforeSweep = harness.state.agents(across: [surfaceID], badgesEnabled: true).first { $0.agent == .claude }
    #expect(beforeSweep?.activity == .awaitingInput)

    harness.livenessSweep()

    // Dead pid pruned, alive pid + awaiting flag preserved.
    let afterSweep = harness.state.agents(across: [surfaceID], badgesEnabled: true).first { $0.agent == .claude }
    #expect(afterSweep?.activity == .awaitingInput)
  }

  // MARK: - Aggregation.

  @Test func agentsAcrossPreservesPerSurfaceDuplicates() {
    var harness = Harness()
    let surfaceA = UUID()
    let surfaceB = UUID()
    let surfaceC = UUID()
    let pid = getpid()

    // Two surfaces both running Claude: the tab badge should show both.
    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceA, pid: pid)))
    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceB, pid: pid)))
    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .codex, surfaceID: surfaceB, pid: pid)))
    // surfaceC has no agent.

    let combined = harness.state.agents(across: [surfaceA, surfaceB, surfaceC], badgesEnabled: true)
    // Sorted by rawValue: claude, claude, codex. None awaiting.
    #expect(
      combined == [
        .init(agent: .claude, activity: .idle),
        .init(agent: .claude, activity: .idle),
        .init(agent: .codex, activity: .idle),
      ]
    )
  }

  @Test func agentsAcrossSortsAwaitingInstancesFirst() {
    var harness = Harness()
    let surfaceA = UUID()
    let surfaceB = UUID()
    let pid = getpid()

    // Two Claude surfaces; only B awaiting. The awaiting instance must lead
    // the row regardless of surface order so the contrast-flipped badge
    // is visible at the front of the avatar group.
    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceA, pid: pid)))
    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceB, pid: pid)))
    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .codex, surfaceID: surfaceA, pid: pid)))
    harness.send(.hookEventReceived(makeEvent(.awaitingInput, agent: .claude, surfaceID: surfaceB)))

    let combined = harness.state.agents(across: [surfaceA, surfaceB], badgesEnabled: true)
    #expect(
      combined == [
        .init(agent: .claude, activity: .awaitingInput),
        .init(agent: .claude, activity: .idle),
        .init(agent: .codex, activity: .idle),
      ]
    )
  }

  // MARK: - Atomic activity.

  @Test func busyWithoutPresenceIsDropped() {
    // A bridge that emits busy events without a matching session_start
    // (or after session_end) must not auto-create a record: pid tracking
    // would have nothing to liveness-check.
    var harness = Harness()
    let surfaceID = UUID()

    harness.send(.hookEventReceived(makeEvent(.busy, agent: .claude, surfaceID: surfaceID, pid: getpid())))

    #expect(harness.state.agents(forSurface: surfaceID, badgesEnabled: true).isEmpty)
    #expect(harness.state.hasActivity(in: [surfaceID]) == false)
  }

  @Test func busyAfterSessionStartFlipsActivityToBusy() {
    var harness = Harness()
    let surfaceID = UUID()

    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: getpid())))
    harness.send(.hookEventReceived(makeEvent(.busy, agent: .claude, surfaceID: surfaceID)))

    let claude = harness.state.agents(across: [surfaceID], badgesEnabled: true).first { $0.agent == .claude }
    #expect(claude?.activity == .busy)
  }
  @Test func ompBusySetsActivity() {
    var harness = Harness()
    let surfaceID = UUID()
    let pid = getpid()

    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .omp, surfaceID: surfaceID, pid: pid)))
    harness.send(.hookEventReceived(makeEvent(.busy, agent: .omp, surfaceID: surfaceID)))

    let omp = harness.state.agents(across: [surfaceID], badgesEnabled: true).first { $0.agent == .omp }
    #expect(omp?.activity == .busy)
    #expect(harness.state.hasActivity(in: [surfaceID]) == true)
  }
  @Test func grokBusySetsActivity() {
    var harness = Harness()
    let surfaceID = UUID()
    let pid = getpid()

    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .grok, surfaceID: surfaceID, pid: pid)))
    harness.send(.hookEventReceived(makeEvent(.busy, agent: .grok, surfaceID: surfaceID)))

    let grok = harness.state.agents(across: [surfaceID], badgesEnabled: true).first { $0.agent == .grok }
    #expect(grok?.activity == .busy)
    #expect(harness.state.hasActivity(in: [surfaceID]) == true)
  }

  @Test func repeatedBusyEventsDoNotMutateRecords() {
    // Repeated `busy` must not re-write `records`, or every dict-observation
    // consumer re-renders per tool call. The reducer's no-op-on-identical
    // activity guard keeps the underlying dict byte-equal.
    var harness = Harness()
    let surfaceID = UUID()

    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: getpid())))
    harness.send(.hookEventReceived(makeEvent(.busy, agent: .claude, surfaceID: surfaceID)))
    let snapshot = harness.state.records

    harness.send(.hookEventReceived(makeEvent(.busy, agent: .claude, surfaceID: surfaceID)))
    harness.send(.hookEventReceived(makeEvent(.busy, agent: .claude, surfaceID: surfaceID)))

    #expect(harness.state.records == snapshot)
  }

  @Test func awaitingInputFlipsActivityWhilePresenceExists() {
    var harness = Harness()
    let surfaceID = UUID()

    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: getpid())))
    harness.send(.hookEventReceived(makeEvent(.awaitingInput, agent: .claude, surfaceID: surfaceID)))

    let claude = harness.state.agents(across: [surfaceID], badgesEnabled: true).first { $0.agent == .claude }
    #expect(claude?.activity == .awaitingInput)
  }

  @Test func nextBusyOverwritesAwaitingInput() {
    // When the user resumes after a permission prompt, Claude's next
    // PreToolUse fires `busy`: atomic overwrite, awaiting flag clears.
    var harness = Harness()
    let surfaceID = UUID()

    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: getpid())))
    harness.send(.hookEventReceived(makeEvent(.awaitingInput, agent: .claude, surfaceID: surfaceID)))
    harness.send(.hookEventReceived(makeEvent(.busy, agent: .claude, surfaceID: surfaceID)))

    let claude = harness.state.agents(across: [surfaceID], badgesEnabled: true).first { $0.agent == .claude }
    #expect(claude?.activity == .busy)
  }

  @Test func idleResetsAwaitingFlag() {
    // The Stop hook (Claude/Codex/Kiro) and Pi's agent_end emit `idle`.
    // Covers the "user denied a plan-commit, conversation ended" path
    // where awaitingInput is set but no further `busy` arrives: Stop
    // owns the turn-boundary reset.
    var harness = Harness()
    let surfaceID = UUID()

    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: getpid())))
    harness.send(.hookEventReceived(makeEvent(.busy, agent: .claude, surfaceID: surfaceID)))
    harness.send(.hookEventReceived(makeEvent(.awaitingInput, agent: .claude, surfaceID: surfaceID)))
    harness.send(.hookEventReceived(makeEvent(.idle, agent: .claude, surfaceID: surfaceID)))

    let claude = harness.state.agents(across: [surfaceID], badgesEnabled: true).first { $0.agent == .claude }
    #expect(claude?.activity == .idle)
  }
  @Test func ompIdleClearsActivityWhileKeepingBadge() {
    var harness = Harness()
    let surfaceID = UUID()
    let pid = getpid()

    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .omp, surfaceID: surfaceID, pid: pid)))
    harness.send(.hookEventReceived(makeEvent(.busy, agent: .omp, surfaceID: surfaceID)))
    harness.send(.hookEventReceived(makeEvent(.idle, agent: .omp, surfaceID: surfaceID)))

    let omp = harness.state.agents(across: [surfaceID], badgesEnabled: true).first { $0.agent == .omp }
    #expect(omp?.activity == .idle)
    #expect(harness.state.agents(forSurface: surfaceID, badgesEnabled: true) == Set([.omp]))
    #expect(harness.state.hasActivity(in: [surfaceID]) == false)
  }
  @Test func grokIdleClearsActivityWhileKeepingBadge() {
    var harness = Harness()
    let surfaceID = UUID()
    let pid = getpid()

    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .grok, surfaceID: surfaceID, pid: pid)))
    harness.send(.hookEventReceived(makeEvent(.busy, agent: .grok, surfaceID: surfaceID)))
    harness.send(.hookEventReceived(makeEvent(.idle, agent: .grok, surfaceID: surfaceID)))

    let grok = harness.state.agents(across: [surfaceID], badgesEnabled: true).first { $0.agent == .grok }
    #expect(grok?.activity == .idle)
    #expect(harness.state.agents(forSurface: surfaceID, badgesEnabled: true) == Set([.grok]))
    #expect(harness.state.hasActivity(in: [surfaceID]) == false)
  }

  @Test func sessionEndClearsActivityForThatAgentOnly() {
    var harness = Harness()
    let surfaceID = UUID()
    let claudePid = getpid()
    // Distinct pid for Codex; we never run the sweep, but using a verifiably
    // dead pid keeps the test honest if a future change adds an implicit one.
    let codexPid = makeDeadPid()

    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: claudePid)))
    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .codex, surfaceID: surfaceID, pid: codexPid)))
    harness.send(.hookEventReceived(makeEvent(.busy, agent: .claude, surfaceID: surfaceID)))
    harness.send(.hookEventReceived(makeEvent(.busy, agent: .codex, surfaceID: surfaceID)))

    harness.send(.hookEventReceived(makeEvent(.sessionEnd, agent: .claude, surfaceID: surfaceID, pid: claudePid)))

    #expect(harness.state.agents(forSurface: surfaceID, badgesEnabled: true) == Set([.codex]))
    let codex = harness.state.agents(across: [surfaceID], badgesEnabled: true).first { $0.agent == .codex }
    #expect(codex?.activity == .busy)
  }

  // MARK: - hasActivity.

  @Test func hasActivityReportsBusyAcrossSurfaces() {
    var harness = Harness()
    let surfaceA = UUID()
    let surfaceB = UUID()
    let surfaceC = UUID()

    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceA, pid: getpid())))
    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .codex, surfaceID: surfaceB, pid: getpid())))
    harness.send(.hookEventReceived(makeEvent(.busy, agent: .codex, surfaceID: surfaceB)))

    #expect(harness.state.hasActivity(in: [surfaceA]) == false)
    #expect(harness.state.hasActivity(in: [surfaceB]) == true)
    #expect(harness.state.hasActivity(in: [surfaceA, surfaceC]) == false)
    #expect(harness.state.hasActivity(in: [surfaceA, surfaceB]) == true)
  }

  @Test func hasActivityIsFalseForAwaitingOnlyRecord() {
    // The shimmer is gated on hasActivity, which tracks active work only.
    // Awaiting-input means the agent is parked on the user, not working, so it
    // must NOT shimmer (the inverted badge already signals the awaiting state).
    var harness = Harness()
    let surfaceID = UUID()

    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: getpid())))
    harness.send(.hookEventReceived(makeEvent(.awaitingInput, agent: .claude, surfaceID: surfaceID)))

    #expect(harness.state.hasActivity(in: [surfaceID]) == false)
    // The badge stays present so the agent is still discoverable while awaiting.
    #expect(harness.state.agents(forSurface: surfaceID, badgesEnabled: true) == Set([.claude]))
  }

  @Test func busyToAwaitingInputDropsActivity() {
    // A busy agent that flips to awaiting-input releases the shimmer: the work
    // it was doing has paused on the user.
    var harness = Harness()
    let surfaceID = UUID()

    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: getpid())))
    harness.send(.hookEventReceived(makeEvent(.busy, agent: .claude, surfaceID: surfaceID)))
    #expect(harness.state.hasActivity(in: [surfaceID]) == true)

    harness.send(.hookEventReceived(makeEvent(.awaitingInput, agent: .claude, surfaceID: surfaceID)))
    #expect(harness.state.hasActivity(in: [surfaceID]) == false)
  }

  // MARK: - Settings gate.

  @Test func badgesGateSuppressesPerSurfaceAndAcrossAccessors() {
    // The user-facing toggle gates the avatar accessors. The shimmer gate
    // (`hasActivity`) is intentionally NOT gated; that's a generic
    // worktree-doing-work signal independent of avatar visibility.
    var harness = Harness()
    let surfaceID = UUID()

    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: getpid())))
    harness.send(.hookEventReceived(makeEvent(.busy, agent: .claude, surfaceID: surfaceID)))

    #expect(harness.state.agents(forSurface: surfaceID, badgesEnabled: false).isEmpty)
    #expect(harness.state.agents(across: [surfaceID], badgesEnabled: false).isEmpty)
    // hasActivity isn't badge-gated.
    #expect(harness.state.hasActivity(in: [surfaceID]) == true)
  }

  // MARK: - restoreFromSnapshot (layouts-embedded).

  @Test func restoreFromLayoutsSeedsRecordsForSurfacesWithLivePids() {
    // Sessions zmx kept alive across quit must surface their agent badges on
    // first paint of the next launch instead of waiting for the next idle/busy
    // transition (agents only emit `session_start` once per process lifetime).
    var harness = Harness()
    let surfaceID = UUID()
    let livePid = getpid()
    let layout = makeLayout(surfaces: [
      (surfaceID, [record(agent: .claude, pids: [livePid], activity: "busy")])
    ])

    harness.restoreFromLayouts([layout])

    #expect(harness.state.bySurface[surfaceID] == [.claude])
    let key = AgentPresenceFeature.PresenceKey(agent: .claude, surfaceID: surfaceID)
    #expect(harness.state.records[key]?.activity == .busy)
    #expect(harness.state.records[key]?.pids == [livePid])
  }

  @Test func restoreFromLayoutsOnlyHydratesSurfacesThatExistInLayouts() {
    // Records live INSIDE layout leaves, so a since-deleted layout's records
    // are gone by construction. This test confirms the implicit filter holds.
    var harness = Harness()
    let known = UUID()
    let layout = makeLayout(surfaces: [
      (known, [record(agent: .claude, pids: [getpid()])])
    ])

    harness.restoreFromLayouts([layout])

    #expect(harness.state.bySurface[known] == [.claude])
    #expect(harness.state.bySurface.count == 1)
  }

  @Test func restoreFromLayoutsDropsRecordsWithOnlyDeadPids() {
    var harness = Harness()
    let surfaceID = UUID()
    let layout = makeLayout(surfaces: [
      (surfaceID, [record(agent: .claude, pids: [makeDeadPid()])])
    ])

    harness.restoreFromLayouts([layout])

    #expect(harness.state.records.isEmpty)
    #expect(harness.state.bySurface[surfaceID] == nil)
  }

  @Test func restoreFromLayoutsKeepsLivePidsAndDropsDeadOnesInSameEntry() {
    var harness = Harness()
    let surfaceID = UUID()
    let live = getpid()
    let dead = makeDeadPid()
    let layout = makeLayout(surfaces: [
      (surfaceID, [record(agent: .claude, pids: [live, dead])])
    ])

    harness.restoreFromLayouts([layout])

    let key = AgentPresenceFeature.PresenceKey(agent: .claude, surfaceID: surfaceID)
    #expect(harness.state.records[key]?.pids == [live])
  }

  @Test func restoreFromLayoutsDoesNotOverwriteRecordsThatRacedAhead() {
    // If a hook event lands between the AppFeature launch effect spawning and
    // the restore dispatch (rare but possible), the live record is the source
    // of truth and the restore must not clobber it.
    var harness = Harness()
    let surfaceID = UUID()
    let racePid: pid_t = getpid()
    harness.send(
      .hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: racePid))
    )
    harness.send(.hookEventReceived(makeEvent(.busy, agent: .claude, surfaceID: surfaceID)))
    let snapshotPid: pid_t = 99_998
    let layout = makeLayout(surfaces: [
      (surfaceID, [record(agent: .claude, pids: [snapshotPid])])
    ])

    harness.restoreFromLayouts([layout])

    let key = AgentPresenceFeature.PresenceKey(agent: .claude, surfaceID: surfaceID)
    #expect(harness.state.records[key]?.activity == .busy)
    #expect(harness.state.records[key]?.pids == [racePid])
  }

  @Test func restoreFromLayoutsHandlesMultipleAgentsPerSurface() {
    // Per AgentPresenceFeature docs: "A surface can host multiple agents
    // (rare, but possible if e.g. Claude spawns Codex)". The per-surface
    // array preserves that multiplicity.
    var harness = Harness()
    let surfaceID = UUID()
    let live = getpid()
    let layout = makeLayout(surfaces: [
      (
        surfaceID,
        [
          record(agent: .claude, pids: [live], activity: "busy"),
          record(agent: .codex, pids: [live], activity: "idle"),
        ]
      )
    ])

    harness.restoreFromLayouts([layout])

    #expect(harness.state.bySurface[surfaceID] == [.claude, .codex])
  }

  @Test func restoreFromLayoutsKeepsLiveAgentAndDropsDeadAgentOnSameSurface() {
    // Mixed-liveness case: one agent on a surface exited cleanly, another is
    // still running. Only the live one's badge should resurrect.
    var harness = Harness()
    let surfaceID = UUID()
    let live = getpid()
    let dead = makeDeadPid()
    let layout = makeLayout(surfaces: [
      (
        surfaceID,
        [
          record(agent: .claude, pids: [live], activity: "busy"),
          record(agent: .codex, pids: [dead], activity: "idle"),
        ]
      )
    ])

    harness.restoreFromLayouts([layout])

    #expect(harness.state.bySurface[surfaceID] == [.claude])
    let claudeKey = AgentPresenceFeature.PresenceKey(agent: .claude, surfaceID: surfaceID)
    let codexKey = AgentPresenceFeature.PresenceKey(agent: .codex, surfaceID: surfaceID)
    #expect(harness.state.records[claudeKey]?.pids == [live])
    #expect(harness.state.records[codexKey] == nil)
  }

  @Test func erroredAgentSortsToFrontOfGroup() {
    var harness = Harness()
    let surfaceID = UUID()
    // Two agents on one surface. By rawValue `claude` sorts before `codex`, so
    // the errored-first key is only proven if the errored `codex` leads.
    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: getpid())))
    harness.send(.hookEventReceived(makeEvent(.sessionStart, agent: .codex, surfaceID: surfaceID, pid: getpid())))
    harness.send(.hookEventReceived(makeEvent(.busy, agent: .claude, surfaceID: surfaceID, pid: getpid())))
    harness.send(.hookEventReceived(makeEvent(.error, agent: .codex, surfaceID: surfaceID, pid: getpid())))

    let instances = harness.state.agents(across: [surfaceID], badgesEnabled: true)
    #expect(instances.map(\.agent) == [.codex, .claude])
    #expect(instances.first?.activity == .error)
  }

  // MARK: - Helpers.

  /// Direct-reducer harness mirroring the singleton's sync API. The sweep timer
  /// effect from `.start` is not exercised here; tests call `livenessSweep()`.
  private struct Harness {
    var state = AgentPresenceFeature.State()
    private let reducer = AgentPresenceFeature()

    @MainActor mutating func send(_ action: AgentPresenceFeature.Action) {
      _ = reducer.reduce(into: &state, action: action)
    }

    @MainActor mutating func livenessSweep() {
      let snapshot: [AgentPresenceFeature.PresenceKey: Set<pid_t>] = state.records
        .compactMapValues { record in record.pids.isEmpty ? nil : record.pids }
      let alive = AgentPresenceFeature.liveness(forSnapshot: snapshot)
      guard !alive.isEmpty else { return }
      send(.livenessSweepResult(snapshot: snapshot, alive: alive))
    }

    /// Drives the 2-phase restore synchronously for tests: stage → liveness →
    /// apply. The live reducer hops the liveness check off the main actor; the
    /// sync harness does it inline so assertions run against the post-apply state.
    @MainActor mutating func restoreFromLayouts(_ layouts: [TerminalLayoutSnapshot]) {
      let staged = AgentPresenceFeature.stageRestore(fromLayouts: layouts)
      let checked = staged.compactMapValues { stage -> AgentPresenceFeature.RestoredRecord? in
        let alive = stage.pids.filter { AgentPresenceFeature.isAlive($0) }
        guard !alive.isEmpty else { return nil }
        return AgentPresenceFeature.RestoredRecord(alivePids: alive, activity: stage.activity)
      }
      guard !checked.isEmpty else { return }
      send(.restoreFromSnapshotChecked(records: checked))
    }
  }

  // MARK: - Layout helpers for restore tests.

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
          TerminalLayoutSnapshot.SurfaceSnapshot(
            id: surface.id,
            workingDirectory: nil,
            agents: surface.agents
          )
        ),
        focusedLeafIndex: 0
      )
    }
    return TerminalLayoutSnapshot(tabs: tabs, selectedTabIndex: 0)
  }

  private func record(
    agent: SkillAgent,
    pids: [Int32],
    activity: String = "idle"
  ) -> TerminalLayoutSnapshot.SurfaceAgentRecord {
    TerminalLayoutSnapshot.SurfaceAgentRecord(agent: agent.rawValue, pids: pids, activity: activity)
  }

  private func makeEvent(
    _ name: AgentHookEvent.EventName, agent: SkillAgent, surfaceID: UUID, pid: pid_t? = nil
  ) -> AgentHookEvent {
    makeEvent(rawEventName: name.rawValue, agent: agent, surfaceID: surfaceID, pid: pid)
  }

  private func makeEvent(
    rawEventName: String, agent: SkillAgent, surfaceID: UUID, pid: pid_t? = nil
  ) -> AgentHookEvent {
    let pidLine = pid.map { ",\n        \"pid\": \($0)" } ?? ""
    let json = """
      {
        "event": "\(rawEventName)",
        "agent": "\(agent.rawValue)",
        "surface_id": "\(surfaceID.uuidString)"\(pidLine)
      }
      """
    guard let event = try? JSONDecoder().decode(AgentHookEvent.self, from: Data(json.utf8)) else {
      preconditionFailure("Failed to parse test event")
    }
    return event
  }

  /// A pid that does not exist on this machine. Walks up from a high value
  /// until `kill(pid, 0)` reports no such process, so the test is independent
  /// of which test runners happen to be live in the host's process table.
  private func makeDeadPid() -> pid_t {
    var candidate: pid_t = 99_999
    while kill(candidate, 0) == 0 {
      candidate -= 1
      if candidate <= 1 {
        preconditionFailure("Could not find a dead pid for the test")
      }
    }
    return candidate
  }
}
