import Darwin
import Foundation
import Observation
import Sharing
import SupacodeSettingsShared

/// Tracks which agents are running in which surface based on hook events
/// from the agent bridges (`session_start` / `session_end` over the socket).
/// Only surface-scoped state lives here — tab and worktree aggregation are
/// resolved at the call site against the current terminal topology so a
/// surface that moves tab (split, drag) never carries stale attribution.
///
/// Liveness is verified independently of the agent's own session-end signal:
/// session_start carries the agent process pid, and a periodic `kill(pid, 0)`
/// sweep evicts records whose tracked pids are dead. This catches agents that
/// don't fire SessionEnd (Codex), crashed agents (no SessionEnd), and Pi
/// shutdowns where the extension exits without sending the event.
@MainActor
@Observable
final class AgentPresenceManager {
  @MainActor static let shared = AgentPresenceManager()

  /// Per-surface agent presence. A surface can host multiple agents (rare,
  /// but possible if e.g. Claude spawns Codex). Order isn't significant —
  /// callers sort for display so avatar ordering stays stable across renders.
  private(set) var bySurface: [UUID: Set<SkillAgent>] = [:]

  /// Per-(surface, agent) record. `count` increments on each session_start
  /// (so /resume etc. balance out before the badge clears); `pids` is the
  /// set of agent pids the bridge has reported, used by the liveness sweep.
  private var records: [PresenceKey: PresenceRecord] = [:]
  private var sweepTask: Task<Void, Never>?

  /// User toggle that gates badge display. Read inside the accessors so the
  /// observed views re-render when it flips.
  @ObservationIgnored
  @Shared(.settingsFile) private var settingsFile: SettingsFile

  private struct PresenceKey: Hashable {
    let surfaceID: UUID
    let agent: SkillAgent
  }

  private struct PresenceRecord: Equatable {
    var count: Int
    var pids: Set<pid_t>
  }

  init() {}

  isolated deinit {
    // Stops the 2s liveness sweep so test-created managers (and any
    // future short-lived owner) don't leak the tick task. Isolated
    // because `sweepTask` is MainActor state.
    sweepTask?.cancel()
  }

  func agents(forSurface id: UUID) -> Set<SkillAgent> {
    guard settingsFile.global.agentPresenceBadgesEnabled else { return [] }
    return bySurface[id] ?? []
  }

  /// Aggregate agents across a caller-resolved surface list. Returns an
  /// array (not a Set) so a tab hosting two surfaces both running Claude
  /// shows two Claude badges. Sorted by agent rawValue so iteration is
  /// stable across renders.
  func agents(across surfaceIDs: some Sequence<UUID>) -> [SkillAgent] {
    guard settingsFile.global.agentPresenceBadgesEnabled else { return [] }
    return surfaceIDs
      .flatMap { bySurface[$0] ?? [] }
      .sorted { $0.rawValue < $1.rawValue }
  }

  /// Drop a closed surface immediately so badges clear without waiting on
  /// a session_end (covers the agent-crashed case once the user closes the
  /// surface).
  func surfaceClosed(_ surfaceID: UUID) {
    surfacesClosed(CollectionOfOne(surfaceID))
  }

  /// Bulk variant for tab-close / worktree-close paths.
  func surfacesClosed(_ surfaceIDs: some Sequence<UUID>) {
    let closing = Set(surfaceIDs)
    for id in closing { bySurface.removeValue(forKey: id) }
    records = records.filter { !closing.contains($0.key.surfaceID) }
  }

  /// Record a hook event from the agent bridge. Currently handles
  /// `session_start` / `session_end`; other event names are ignored here
  /// (busy state and notifications flow through their own pipelines).
  func record(event: AgentHookEvent) {
    guard let agent = SkillAgent(rawValue: event.agent) else { return }
    let key = PresenceKey(surfaceID: event.surfaceID, agent: agent)
    switch event.eventName {
    case .sessionStart:
      var record = records[key] ?? PresenceRecord(count: 0, pids: [])
      record.count += 1
      if let pid = event.pid { record.pids.insert(pid) }
      records[key] = record
      ensureLivenessSweepRunning()
    case .sessionEnd:
      guard var record = records[key] else { return }
      record.count -= 1
      if let pid = event.pid { record.pids.remove(pid) }
      // Pid set is the source of truth — Claude fires SessionStart on
      // /resume, /clear, /compact (one process, multiple events) but
      // SessionEnd only at exit, so a count-only check would leak a
      // record with `count > 0, pids = []` that the liveness sweep
      // (which filters `!pids.isEmpty`) never collects.
      if record.count <= 0 || (event.pid != nil && record.pids.isEmpty) {
        records.removeValue(forKey: key)
      } else {
        records[key] = record
      }
    default:
      return
    }
    rebuildPresenceForSurface(event.surfaceID)
  }

  // MARK: - Liveness.

  /// Period between liveness sweeps. The sweep only runs `kill(pid, 0)` on
  /// the registered set, so the cost scales with active sessions, not with
  /// the system process count.
  private static let livenessSweepInterval: Duration = .seconds(2)

  private func ensureLivenessSweepRunning() {
    guard sweepTask == nil else { return }
    sweepTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: Self.livenessSweepInterval)
        await self?.livenessSweep()
      }
    }
  }

  /// For each record with tracked pids, prune dead pids. When a record's
  /// pid set goes empty after pruning, drop the record entirely — the
  /// session_end signal never came (agent crashed, force-killed, or
  /// shipped without a SessionEnd hook event like Codex).
  func livenessSweep() {
    var dirtySurfaces: Set<UUID> = []
    for (key, record) in records where !record.pids.isEmpty {
      // Defensive `pid > 0` guard: `kill(0, 0)` and `kill(-N, 0)` both
      // succeed against the caller's process group, so a non-positive
      // pid that slipped past the decoder would lie about liveness.
      let alive = record.pids.filter { $0 > 0 && kill($0, 0) == 0 }
      guard alive != record.pids else { continue }
      if alive.isEmpty {
        records.removeValue(forKey: key)
      } else {
        records[key] = PresenceRecord(count: record.count, pids: alive)
      }
      dirtySurfaces.insert(key.surfaceID)
    }
    for surfaceID in dirtySurfaces { rebuildPresenceForSurface(surfaceID) }
  }

  private func rebuildPresenceForSurface(_ surfaceID: UUID) {
    let agents = Set(
      records.compactMap { entry in
        entry.key.surfaceID == surfaceID ? entry.key.agent : nil
      }
    )
    if agents.isEmpty {
      bySurface.removeValue(forKey: surfaceID)
    } else {
      bySurface[surfaceID] = agents
    }
  }
}
