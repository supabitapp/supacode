import Darwin
import Foundation
import Observation
import Sharing
import SupacodeSettingsShared

/// Tracks which agents are present and what they're doing per surface,
/// driven by hook events from the agent bridges (session lifecycle plus
/// per-turn activity). Only surface-scoped state lives here — tab and
/// worktree aggregation are resolved at the call site against the current
/// terminal topology so a surface that moves tab (split, drag) never carries
/// stale attribution.
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

  /// Activity state per (surface, agent). Set atomically by the wire events
  /// `busy` / `awaiting_input` / `idle` — each event overwrites the previous
  /// state. No counters, no on/off pairs: the agent's Stop equivalent is the
  /// natural reset that fires `idle`. `awaitingInput` reflects an explicit
  /// prompt the user must answer (Claude `Notification` plus per-tool matchers
  /// on `AskUserQuestion` / `ExitPlanMode`); any bridge can emit it.
  enum Activity: Sendable, Equatable {
    case idle
    case busy
    case awaitingInput
  }

  /// One badge worth of state — an agent in a specific surface, plus its
  /// current activity. Surface ID is intentionally not carried: callers
  /// already filtered by surface set.
  struct AgentInstance: Hashable, Sendable {
    let agent: SkillAgent
    let activity: Activity

    /// Convenience for views that only care about the awaiting-input cue
    /// (the avatar group's contrast-flip rendering).
    var awaitingInput: Bool { activity == .awaitingInput }
  }

  /// Per-surface agent presence. A surface can host multiple agents (rare,
  /// but possible if e.g. Claude spawns Codex). Order isn't significant —
  /// callers sort for display so avatar ordering stays stable across renders.
  private(set) var bySurface: [UUID: Set<SkillAgent>] = [:]

  /// Per-(surface, agent) record. Pids drive both the liveness sweep
  /// and record disposal — every bridge today (Claude/Codex/Kiro hooks,
  /// Pi extension) sends a pid in the envelope.
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
    var pids: Set<pid_t>
    var activity: Activity = .idle
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

  /// One `AgentInstance` per (surface, agent) pair across the caller-resolved
  /// surface list. Duplicates preserved (a tab hosting two surfaces both
  /// running Claude shows two Claude badges). Sorted with awaiting-input
  /// instances first (contrast-flipped badges lead the row) then by agent
  /// rawValue so iteration is stable across renders.
  func agents(across surfaceIDs: some Sequence<UUID>) -> [AgentInstance] {
    guard settingsFile.global.agentPresenceBadgesEnabled else { return [] }
    return
      surfaceIDs
      .flatMap { surfaceID -> [AgentInstance] in
        (bySurface[surfaceID] ?? []).map { agent in
          let activity = records[PresenceKey(surfaceID: surfaceID, agent: agent)]?.activity ?? .idle
          return AgentInstance(agent: agent, activity: activity)
        }
      }
      .sorted { lhs, rhs in
        if lhs.awaitingInput != rhs.awaitingInput { return lhs.awaitingInput }
        return lhs.agent.rawValue < rhs.agent.rawValue
      }
  }

  /// True when any agent in the surface set is busy or awaiting input.
  /// Drives the sidebar shimmer alongside ghostty progress state — NOT
  /// gated by `agentPresenceBadgesEnabled` since the shimmer pre-existed
  /// the badge feature and is a generic "this worktree is doing work"
  /// signal independent of avatar visibility.
  func hasActivity(in surfaceIDs: some Sequence<UUID>) -> Bool {
    records.contains { entry in
      entry.value.activity != .idle && surfaceIDs.contains(entry.key.surfaceID)
    }
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

  /// Record a hook event from the agent bridge. Handles session lifecycle
  /// (`session_start` / `session_end`) and per-turn activity
  /// (`busy` / `awaiting_input` / `idle` — atomic state-set). Activity events
  /// only mutate existing records — they never create one, so a stray
  /// `busy` without a prior session_start is dropped.
  func record(event: AgentHookEvent) {
    guard let agent = SkillAgent(rawValue: event.agent) else { return }
    let key = PresenceKey(surfaceID: event.surfaceID, agent: agent)
    switch event.eventName {
    case .sessionStart:
      guard let pid = event.pid else { return }
      var record = records[key] ?? PresenceRecord(pids: [])
      record.pids.insert(pid)
      records[key] = record
      ensureLivenessSweepRunning()
      rebuildPresenceForSurface(event.surfaceID)
    case .sessionEnd:
      guard let pid = event.pid, var record = records[key] else { return }
      record.pids.remove(pid)
      if record.pids.isEmpty {
        records.removeValue(forKey: key)
      } else {
        records[key] = record
      }
      rebuildPresenceForSurface(event.surfaceID)
    case .busy:
      setActivity(.busy, for: key)
    case .awaitingInput:
      setActivity(.awaitingInput, for: key)
    case .idle:
      setActivity(.idle, for: key)
    default:
      return
    }
  }

  private func setActivity(_ activity: Activity, for key: PresenceKey) {
    // No-op on identical activity so PreToolUse/PostToolUse busy storms don't churn `@Observable`.
    guard var record = records[key], record.activity != activity else { return }
    record.activity = activity
    records[key] = record
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
        self?.livenessSweep()
      }
    }
  }

  /// For each record with tracked pids, prune dead pids. When a record's
  /// pid set goes empty after pruning, drop the record entirely — the
  /// session_end signal never came (agent crashed, force-killed, or
  /// shipped without a SessionEnd hook event like Codex). Surviving records
  /// keep their `activity` — partial-pid eviction must not silently clear
  /// in-flight state.
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
        var updated = record
        updated.pids = alive
        records[key] = updated
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
