import Darwin
import Dependencies
import Foundation
import Sharing
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct AgentPresenceManagerTests {
  @Test func sessionStartRegistersAgentForSurface() {
    let manager = AgentPresenceManager()
    let surfaceID = UUID()

    manager.record(event: makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: getpid()))

    #expect(manager.agents(forSurface: surfaceID) == Set([.claude]))
  }

  @Test func sessionStartWithoutPidIsIgnored() {
    // Every bridge today (Claude/Codex/Kiro hooks, Pi extension) sends a
    // pid in the envelope. A pid-less event is treated as malformed —
    // accepting it would create a record the liveness sweep can't reap.
    let manager = AgentPresenceManager()
    let surfaceID = UUID()

    manager.record(event: makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID))

    #expect(manager.agents(forSurface: surfaceID).isEmpty)
  }

  @Test func sessionEndRemovesAgentForSurface() {
    let manager = AgentPresenceManager()
    let surfaceID = UUID()
    let pid = getpid()

    manager.record(event: makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: pid))
    manager.record(event: makeEvent(.sessionEnd, agent: .claude, surfaceID: surfaceID, pid: pid))

    #expect(manager.agents(forSurface: surfaceID).isEmpty)
  }

  @Test func sessionStartIsIdempotentForSameProcessPid() {
    // Reproduces the Claude `/resume` flow: SessionStart fires on startup
    // AND on resume (one process, two events, same pid). One SessionEnd
    // clears the record — there's only one process to liveness-track.
    let manager = AgentPresenceManager()
    let surfaceID = UUID()
    let agentPid: pid_t = getpid()

    manager.record(event: makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: agentPid))
    manager.record(event: makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: agentPid))
    manager.record(event: makeEvent(.sessionEnd, agent: .claude, surfaceID: surfaceID, pid: agentPid))

    #expect(manager.agents(forSurface: surfaceID).isEmpty)
  }

  @Test func surfaceClosedClearsEntriesEvenWithoutSessionEnd() {
    let manager = AgentPresenceManager()
    let surfaceID = UUID()

    manager.record(event: makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: getpid()))
    #expect(manager.agents(forSurface: surfaceID) == Set([.claude]))

    manager.surfaceClosed(surfaceID)

    #expect(manager.agents(forSurface: surfaceID).isEmpty)
  }

  @Test func surfaceClosedClearsAwaitingState() {
    // C10(d): closing a surface mid-awaiting-input clears the record so
    // the sidebar / tab badges drop to idle without waiting on the agent
    // to fire idle (which it can't — the user closed the tab).
    let manager = AgentPresenceManager()
    let surfaceID = UUID()

    manager.record(event: makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: getpid()))
    manager.record(event: makeEvent(.awaitingInput, agent: .claude, surfaceID: surfaceID))
    #expect(manager.hasActivity(in: [surfaceID]))

    manager.surfaceClosed(surfaceID)

    #expect(manager.hasActivity(in: [surfaceID]) == false)
    #expect(manager.agents(forSurface: surfaceID).isEmpty)
  }

  @Test func unknownAgentNameIsIgnored() {
    let manager = AgentPresenceManager()
    let surfaceID = UUID()
    let json = """
      {
        "event": "session_start",
        "agent": "imaginary-agent",
        "surface_id": "\(surfaceID.uuidString)"
      }
      """
    guard case .event(let parsed) = AgentHookSocketServer.parse(data: Data(json.utf8)) else {
      Issue.record("Expected event")
      return
    }
    manager.record(event: parsed)

    #expect(manager.agents(forSurface: surfaceID).isEmpty)
  }

  @Test func unknownEventNameIsIgnored() {
    let manager = AgentPresenceManager()
    let surfaceID = UUID()
    manager.record(
      event: makeEvent(
        rawEventName: "future_event_we_dont_know",
        agent: .claude, surfaceID: surfaceID))

    #expect(manager.agents(forSurface: surfaceID).isEmpty)
  }

  // MARK: - Liveness.

  @Test func livenessSweepEvictsRecordsForDeadPid() {
    let manager = AgentPresenceManager()
    let surfaceID = UUID()
    // Use the test process's own pid — guaranteed alive, and unlike pid 1
    // (launchd) it isn't signal-protected so `kill(pid, 0)` returns 0.
    let alivePid: pid_t = getpid()
    let deadPid = makeDeadPid()

    manager.record(event: makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: alivePid))
    manager.record(event: makeEvent(.sessionStart, agent: .codex, surfaceID: surfaceID, pid: deadPid))

    #expect(manager.agents(forSurface: surfaceID) == Set([.claude, .codex]))

    manager.livenessSweep()

    // Codex's pid is dead → record evicted. Claude's pid is alive → kept.
    #expect(manager.agents(forSurface: surfaceID) == Set([.claude]))
  }

  @Test func livenessSweepEvictingAwaitingRecordClearsBadgeImmediately() {
    // C10(c): a Claude process that crashes mid-awaiting-input would leave
    // a sticky orange badge until the user closed the surface. The pid
    // sweep must drop the awaiting record entirely, not just downgrade it.
    let manager = AgentPresenceManager()
    let surfaceID = UUID()
    let deadPid = makeDeadPid()

    manager.record(event: makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: deadPid))
    manager.record(event: makeEvent(.awaitingInput, agent: .claude, surfaceID: surfaceID))
    #expect(manager.hasActivity(in: [surfaceID]))

    manager.livenessSweep()

    #expect(manager.agents(forSurface: surfaceID).isEmpty)
    #expect(manager.hasActivity(in: [surfaceID]) == false)
  }

  @Test func livenessSweepPartialPidEvictionPreservesActivity() {
    // C1: when only some of a multi-pid record's pids die (e.g. Claude
    // crash + reopen in the same surface, where SessionStart for the new
    // pid union-inserts), the surviving record's activity must NOT be
    // wiped to .idle.
    let manager = AgentPresenceManager()
    let surfaceID = UUID()
    let alivePid: pid_t = getpid()
    let deadPid = makeDeadPid()

    manager.record(event: makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: deadPid))
    manager.record(event: makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: alivePid))
    manager.record(event: makeEvent(.awaitingInput, agent: .claude, surfaceID: surfaceID))

    let beforeSweep = manager.agents(across: [surfaceID]).first { $0.agent == .claude }
    #expect(beforeSweep?.activity == .awaitingInput)

    manager.livenessSweep()

    // Dead pid pruned, alive pid + awaiting flag preserved.
    let afterSweep = manager.agents(across: [surfaceID]).first { $0.agent == .claude }
    #expect(afterSweep?.activity == .awaitingInput)
  }

  // MARK: - Aggregation.

  @Test func agentsAcrossPreservesPerSurfaceDuplicates() {
    let manager = AgentPresenceManager()
    let surfaceA = UUID()
    let surfaceB = UUID()
    let surfaceC = UUID()
    let pid = getpid()

    // Two surfaces both running Claude — the tab badge should show both.
    manager.record(event: makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceA, pid: pid))
    manager.record(event: makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceB, pid: pid))
    manager.record(event: makeEvent(.sessionStart, agent: .codex, surfaceID: surfaceB, pid: pid))
    // surfaceC has no agent.

    let combined = manager.agents(across: [surfaceA, surfaceB, surfaceC])
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
    let manager = AgentPresenceManager()
    let surfaceA = UUID()
    let surfaceB = UUID()
    let pid = getpid()

    // Two Claude surfaces; only B awaiting. The awaiting instance must lead
    // the row regardless of surface order so the contrast-flipped badge
    // is visible at the front of the avatar group.
    manager.record(event: makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceA, pid: pid))
    manager.record(event: makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceB, pid: pid))
    manager.record(event: makeEvent(.sessionStart, agent: .codex, surfaceID: surfaceA, pid: pid))
    manager.record(event: makeEvent(.awaitingInput, agent: .claude, surfaceID: surfaceB))

    let combined = manager.agents(across: [surfaceA, surfaceB])
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
    // (or after session_end) must not auto-create a record — the pid
    // tracking would have nothing to liveness-check.
    let manager = AgentPresenceManager()
    let surfaceID = UUID()

    manager.record(event: makeEvent(.busy, agent: .claude, surfaceID: surfaceID, pid: getpid()))

    #expect(manager.agents(forSurface: surfaceID).isEmpty)
    #expect(manager.hasActivity(in: [surfaceID]) == false)
  }

  @Test func busyAfterSessionStartFlipsActivityToBusy() {
    let manager = AgentPresenceManager()
    let surfaceID = UUID()

    manager.record(event: makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: getpid()))
    manager.record(event: makeEvent(.busy, agent: .claude, surfaceID: surfaceID))

    let claude = manager.agents(across: [surfaceID]).first { $0.agent == .claude }
    #expect(claude?.activity == .busy)
  }

  @Test func repeatedBusyEventsAreIdempotentAndDoNotChurnObservation() {
    // Repeated `busy` must not re-write `records`, or every `agents(across:)` consumer re-renders per tool call.
    let manager = AgentPresenceManager()
    let surfaceID = UUID()

    manager.record(event: makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: getpid()))
    manager.record(event: makeEvent(.busy, agent: .claude, surfaceID: surfaceID))

    let observationFired = ObservationFlag()
    withObservationTracking {
      _ = manager.agents(across: [surfaceID])
    } onChange: {
      observationFired.value = true
    }

    manager.record(event: makeEvent(.busy, agent: .claude, surfaceID: surfaceID))
    manager.record(event: makeEvent(.busy, agent: .claude, surfaceID: surfaceID))

    let claude = manager.agents(across: [surfaceID]).first { $0.agent == .claude }
    #expect(claude?.activity == .busy)
    #expect(observationFired.value == false)
  }

  @Test func awaitingInputFlipsActivityWhilePresenceExists() {
    let manager = AgentPresenceManager()
    let surfaceID = UUID()

    manager.record(event: makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: getpid()))
    manager.record(event: makeEvent(.awaitingInput, agent: .claude, surfaceID: surfaceID))

    let claude = manager.agents(across: [surfaceID]).first { $0.agent == .claude }
    #expect(claude?.activity == .awaitingInput)
  }

  @Test func nextBusyOverwritesAwaitingInput() {
    // When the user resumes after a permission prompt, Claude's next
    // PreToolUse fires `busy` — atomic overwrite, awaiting flag clears.
    let manager = AgentPresenceManager()
    let surfaceID = UUID()

    manager.record(event: makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: getpid()))
    manager.record(event: makeEvent(.awaitingInput, agent: .claude, surfaceID: surfaceID))
    manager.record(event: makeEvent(.busy, agent: .claude, surfaceID: surfaceID))

    let claude = manager.agents(across: [surfaceID]).first { $0.agent == .claude }
    #expect(claude?.activity == .busy)
  }

  @Test func idleResetsAwaitingFlag() {
    // The Stop hook (Claude/Codex/Kiro) and Pi's agent_end emit `idle`.
    // Covers the "user denied a plan-commit, conversation ended" path
    // where awaitingInput is set but no further `busy` arrives — Stop
    // owns the turn-boundary reset.
    let manager = AgentPresenceManager()
    let surfaceID = UUID()

    manager.record(event: makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: getpid()))
    manager.record(event: makeEvent(.busy, agent: .claude, surfaceID: surfaceID))
    manager.record(event: makeEvent(.awaitingInput, agent: .claude, surfaceID: surfaceID))
    manager.record(event: makeEvent(.idle, agent: .claude, surfaceID: surfaceID))

    let claude = manager.agents(across: [surfaceID]).first { $0.agent == .claude }
    #expect(claude?.activity == .idle)
  }

  @Test func sessionEndClearsActivityForThatAgentOnly() {
    let manager = AgentPresenceManager()
    let surfaceID = UUID()
    let claudePid = getpid()
    // Distinct pid for Codex; we never run the sweep, but using a verifiably
    // dead pid keeps the test honest if a future change adds an implicit one.
    let codexPid = makeDeadPid()

    manager.record(event: makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: claudePid))
    manager.record(event: makeEvent(.sessionStart, agent: .codex, surfaceID: surfaceID, pid: codexPid))
    manager.record(event: makeEvent(.busy, agent: .claude, surfaceID: surfaceID))
    manager.record(event: makeEvent(.busy, agent: .codex, surfaceID: surfaceID))

    manager.record(event: makeEvent(.sessionEnd, agent: .claude, surfaceID: surfaceID, pid: claudePid))

    #expect(manager.agents(forSurface: surfaceID) == Set([.codex]))
    let codex = manager.agents(across: [surfaceID]).first { $0.agent == .codex }
    #expect(codex?.activity == .busy)
  }

  // MARK: - hasActivity.

  @Test func hasActivityReportsBusyAcrossSurfaces() {
    let manager = AgentPresenceManager()
    let surfaceA = UUID()
    let surfaceB = UUID()
    let surfaceC = UUID()

    manager.record(event: makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceA, pid: getpid()))
    manager.record(event: makeEvent(.sessionStart, agent: .codex, surfaceID: surfaceB, pid: getpid()))
    manager.record(event: makeEvent(.busy, agent: .codex, surfaceID: surfaceB))

    #expect(manager.hasActivity(in: [surfaceA]) == false)
    #expect(manager.hasActivity(in: [surfaceB]) == true)
    #expect(manager.hasActivity(in: [surfaceA, surfaceC]) == false)
    #expect(manager.hasActivity(in: [surfaceA, surfaceB]) == true)
  }

  @Test func hasActivityIsTrueForAwaitingOnlyRecord() {
    // C10(b): the shimmer is gated on hasActivity, which must light up
    // for awaiting-input even when no tool is currently running (e.g.
    // permission prompt without a paired busy event).
    let manager = AgentPresenceManager()
    let surfaceID = UUID()

    manager.record(event: makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: getpid()))
    manager.record(event: makeEvent(.awaitingInput, agent: .claude, surfaceID: surfaceID))

    #expect(manager.hasActivity(in: [surfaceID]) == true)
  }

  // MARK: - Settings gate.

  @Test func badgesGateSuppressesPerSurfaceAndAcrossAccessors() {
    // C10(a): the user-facing toggle gates the avatar accessors. The
    // shimmer gate (`hasActivity`) is intentionally NOT gated — see the
    // doc comment on the manager.
    try? withDependencies {
      $0.defaultFileStorage = .inMemory
    } operation: {
      $settingsFile.withLock {
        $0.global.agentPresenceBadgesEnabled = false
      }
      let manager = AgentPresenceManager()
      let surfaceID = UUID()

      manager.record(event: makeEvent(.sessionStart, agent: .claude, surfaceID: surfaceID, pid: getpid()))
      manager.record(event: makeEvent(.busy, agent: .claude, surfaceID: surfaceID))

      #expect(manager.agents(forSurface: surfaceID).isEmpty)
      #expect(manager.agents(across: [surfaceID]).isEmpty)
      // hasActivity stays true — generic worktree-doing-work signal
      // independent of avatar visibility.
      #expect(manager.hasActivity(in: [surfaceID]) == true)
    }
  }

  // MARK: - Helpers.

  @Shared(.settingsFile) private var settingsFile: SettingsFile

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
    guard case .event(let event) = AgentHookSocketServer.parse(data: Data(json.utf8)) else {
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

/// `withObservationTracking`'s `onChange` is `@Sendable`; `nonisolated(unsafe)`
/// lets the MainActor test mutate the flag without tripping isolation.
private final class ObservationFlag: @unchecked Sendable {
  nonisolated(unsafe) var value = false
}
