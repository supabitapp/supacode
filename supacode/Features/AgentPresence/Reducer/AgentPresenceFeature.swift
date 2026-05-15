import ComposableArchitecture
import Darwin
import Foundation
import Sharing
import SupacodeSettingsShared

private let presenceLogger = SupaLogger("AgentPresence")

@Reducer
struct AgentPresenceFeature {
  /// Activity state per (surface, agent). Set atomically by the wire events
  /// `busy` / `awaiting_input` / `idle`. The agent's Stop equivalent fires
  /// `idle`; `awaiting_input` is an explicit prompt the user must answer.
  enum Activity: Sendable, Equatable {
    case awaitingInput
    case busy
    case idle
  }

  /// One badge worth of state. Surface ID is redundant; callers scope by surface set.
  struct AgentInstance: Hashable, Sendable {
    let agent: SkillAgent
    let activity: Activity

    /// The avatar group flips contrast on awaiting-input instances.
    var awaitingInput: Bool { activity == .awaitingInput }
  }

  struct PresenceKey: Hashable, Sendable {
    let agent: SkillAgent
    let surfaceID: UUID
  }

  struct PresenceRecord: Equatable, Sendable {
    var activity: Activity = .idle
    var pids: Set<pid_t>
  }

  // `nonisolated` is load-bearing here. Without it the @Reducer macro
  // propagates main-actor isolation onto CancelID's Hashable witness, which
  // then can't satisfy the Sendable requirement in `.cancellable(id:)`.
  nonisolated enum CancelID: Hashable, Sendable { case livenessSweep }

  enum Action {
    case delegate(Delegate)
    case hookEventReceived(AgentHookEvent)
    case livenessSweepTick
    case start
    case stop
    case surfaceClosed(UUID)
    case surfacesClosed(Set<UUID>)

    enum Delegate: Equatable, Sendable {
      /// Surfaces whose presence record was added, removed, or had its activity flip.
      /// Parent fans out per-row `agentSnapshotChanged` via the `surfaceToItemID` reverse index.
      case surfacesChanged(Set<UUID>)
    }
  }

  @ObservableState
  struct State: Equatable {
    /// Per-(surface, agent) record. Pids drive the liveness sweep and record
    /// disposal. All bridges require a pid in the envelope.
    var records: [PresenceKey: PresenceRecord] = [:]
    /// Per-surface agent presence. A surface can host multiple agents (rare,
    /// but possible if e.g. Claude spawns Codex). Order not guaranteed; sort before display.
    var bySurface: [UUID: Set<SkillAgent>] = [:]
  }

  /// Period between liveness sweeps. Cost scales with active sessions, not
  /// with the system process count. `nonisolated` so the Reduce closure can
  /// read it without crossing main-actor isolation.
  nonisolated static let livenessSweepInterval: Duration = .seconds(2)

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      @Dependency(\.continuousClock) var clock
      switch action {
      case .delegate:
        return .none

      case .hookEventReceived(let event):
        let changed = Self.apply(event: event, into: &state)
        return Self.surfacesChangedEffect(changed)

      case .livenessSweepTick:
        let changed = Self.sweepLiveness(into: &state)
        return Self.surfacesChangedEffect(changed)

      case .start:
        return .run { send in
          for await _ in clock.timer(interval: Self.livenessSweepInterval) {
            await send(.livenessSweepTick)
          }
        }
        .cancellable(id: CancelID.livenessSweep, cancelInFlight: true)

      case .stop:
        return .cancel(id: CancelID.livenessSweep)

      case .surfaceClosed(let id):
        Self.drop(surfaces: [id], from: &state)
        return Self.surfacesChangedEffect([id])

      case .surfacesClosed(let ids):
        Self.drop(surfaces: ids, from: &state)
        return Self.surfacesChangedEffect(ids)
      }
    }
  }

  private static func surfacesChangedEffect(_ surfaces: Set<UUID>) -> Effect<Action> {
    guard !surfaces.isEmpty else { return .none }
    return .send(.delegate(.surfacesChanged(surfaces)))
  }

  // MARK: - Mutators.

  /// Returns the surface IDs whose row-visible state changed, so the parent can fan
  /// out per-row `agentSnapshotChanged` deltas without inspecting `bySurface` itself.
  private static func apply(event: AgentHookEvent, into state: inout State) -> Set<UUID> {
    guard let agent = SkillAgent(rawValue: event.agent) else { return [] }
    let key = PresenceKey(agent: agent, surfaceID: event.surfaceID)
    switch event.eventName {
    case .sessionStart:
      guard let pid = event.pid else { return [] }
      var record = state.records[key] ?? PresenceRecord(pids: [])
      let inserted = record.pids.insert(pid).inserted
      state.records[key] = record
      rebuildPresence(forSurface: event.surfaceID, in: &state)
      return inserted ? [event.surfaceID] : []
    case .sessionEnd:
      guard let pid = event.pid, var record = state.records[key] else { return [] }
      let removed = record.pids.remove(pid) != nil
      if record.pids.isEmpty {
        state.records.removeValue(forKey: key)
      } else {
        state.records[key] = record
      }
      rebuildPresence(forSurface: event.surfaceID, in: &state)
      return removed ? [event.surfaceID] : []
    case .busy:
      return setActivity(.busy, for: key, in: &state) ? [event.surfaceID] : []
    case .awaitingInput:
      return setActivity(.awaitingInput, for: key, in: &state) ? [event.surfaceID] : []
    case .idle:
      return setActivity(.idle, for: key, in: &state) ? [event.surfaceID] : []
    case .notification, .none:
      return []
    }
  }

  /// No-op on identical activity so PreToolUse/PostToolUse storms don't churn observers.
  /// Returns true when the record actually flipped.
  private static func setActivity(_ activity: Activity, for key: PresenceKey, in state: inout State) -> Bool {
    guard var record = state.records[key], record.activity != activity else { return false }
    record.activity = activity
    state.records[key] = record
    return true
  }

  private static func drop(surfaces: Set<UUID>, from state: inout State) {
    for id in surfaces { state.bySurface.removeValue(forKey: id) }
    state.records = state.records.filter { !surfaces.contains($0.key.surfaceID) }
  }

  /// For each record with tracked pids, prune dead pids. When a record's pid
  /// set goes empty after pruning, drop the record entirely (the agent
  /// crashed, was force-killed, or shipped without a SessionEnd event like
  /// Codex). Surviving records keep their `activity`; partial-pid eviction
  /// must not silently clear in-flight state.
  private static func sweepLiveness(into state: inout State) -> Set<UUID> {
    var dirtySurfaces: Set<UUID> = []
    for (key, record) in state.records where !record.pids.isEmpty {
      // Defensive `pid > 0` guard: `kill(0, 0)` and `kill(-N, 0)` both
      // succeed against the caller's process group, so a non-positive
      // pid that slipped past the decoder would lie about liveness.
      let alive = record.pids.filter { $0 > 0 && kill($0, 0) == 0 }
      guard alive != record.pids else { continue }
      if alive.isEmpty {
        state.records.removeValue(forKey: key)
      } else {
        var updated = record
        updated.pids = alive
        state.records[key] = updated
      }
      dirtySurfaces.insert(key.surfaceID)
    }
    for surfaceID in dirtySurfaces { rebuildPresence(forSurface: surfaceID, in: &state) }
    return dirtySurfaces
  }

  private static func rebuildPresence(forSurface surfaceID: UUID, in state: inout State) {
    let agents = Set(
      state.records.compactMap { entry in
        entry.key.surfaceID == surfaceID ? entry.key.agent : nil
      },
    )
    if agents.isEmpty {
      state.bySurface.removeValue(forKey: surfaceID)
    } else {
      state.bySurface[surfaceID] = agents
    }
  }
}

extension AgentPresenceFeature.State {
  /// Agents on a single surface. Empty when badges are disabled by the user.
  func agents(forSurface id: UUID, badgesEnabled: Bool) -> Set<SkillAgent> {
    guard badgesEnabled else { return [] }
    return bySurface[id] ?? []
  }

  /// One `AgentInstance` per (surface, agent) pair across the given surface list.
  /// Duplicates preserved (a tab hosting two surfaces both
  /// running Claude shows two Claude badges). Sorted with awaiting-input
  /// instances first (contrast-flipped badges lead the row) then by agent
  /// rawValue so iteration is stable across renders.
  func agents(
    across surfaceIDs: some Sequence<UUID>,
    badgesEnabled: Bool,
  ) -> [AgentPresenceFeature.AgentInstance] {
    guard badgesEnabled else { return [] }
    return
      surfaceIDs
      .flatMap { surfaceID -> [AgentPresenceFeature.AgentInstance] in
        (bySurface[surfaceID] ?? []).map { agent in
          let activity =
            records[AgentPresenceFeature.PresenceKey(agent: agent, surfaceID: surfaceID)]?.activity ?? .idle
          return AgentPresenceFeature.AgentInstance(agent: agent, activity: activity)
        }
      }
      .sorted { lhs, rhs in
        if lhs.awaitingInput != rhs.awaitingInput { return lhs.awaitingInput }
        return lhs.agent.rawValue < rhs.agent.rawValue
      }
  }

  /// Any agent on any of the listed surfaces is busy or awaiting input. Drives
  /// the sidebar shimmer alongside Ghostty progress state; not gated by the
  /// badge toggle since the shimmer is a generic "this worktree is doing work"
  /// signal independent of avatar visibility.
  func hasActivity(in surfaceIDs: some Sequence<UUID>) -> Bool {
    let surfaceSet = Set(surfaceIDs)
    return records.contains { entry in
      entry.value.activity != .idle && surfaceSet.contains(entry.key.surfaceID)
    }
  }
}
