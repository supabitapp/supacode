import Darwin
import Foundation
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
    // Sorted by rawValue: claude, claude, codex.
    #expect(combined == [.claude, .claude, .codex])
  }

  // MARK: - Helpers.

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
