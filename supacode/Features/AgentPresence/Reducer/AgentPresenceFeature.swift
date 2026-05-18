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
  enum Activity: String, Sendable, Equatable {
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

  // `nonisolated` so `stageRestore` (off-main at launch) can use Hashable.
  nonisolated struct PresenceKey: Hashable, Sendable {
    let agent: SkillAgent
    let surfaceID: UUID
  }

  nonisolated struct PresenceRecord: Equatable, Sendable {
    var activity: Activity = .idle
    var pids: Set<pid_t>
  }

  nonisolated struct RestoredRecord: Sendable {
    let alivePids: Set<pid_t>
    let activity: Activity
  }

  // `nonisolated` is load-bearing here. Without it the @Reducer macro
  // propagates main-actor isolation onto CancelID's Hashable witness, which
  // then can't satisfy the Sendable requirement in `.cancellable(id:)`.
  nonisolated enum CancelID: Hashable, Sendable { case livenessSweep }

  enum Action {
    case delegate(Delegate)
    case hookEventReceived(AgentHookEvent)
    case livenessSweepTick
    case livenessSweepResult(snapshot: [PresenceKey: Set<pid_t>], alive: [PresenceKey: Set<pid_t>])
    case start
    case stop
    case surfaceClosed(UUID)
    case surfacesClosed(Set<UUID>)
    /// Stage records for the off-main liveness pass. Apply lands as
    /// `restoreFromSnapshotChecked` so `kill(2)` never runs on the main actor.
    case restoreFromSnapshot(staged: [PresenceKey: StagedRestore])
    case restoreFromSnapshotChecked(records: [PresenceKey: RestoredRecord])

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
        // Run `kill(2)` off the main actor; the reducer body is shared with action-burst paths.
        let snapshot: [PresenceKey: Set<pid_t>] = state.records
          .compactMapValues { record in record.pids.isEmpty ? nil : record.pids }
        guard !snapshot.isEmpty else { return .none }
        return .run { send in
          let alive = Self.liveness(forSnapshot: snapshot)
          guard !alive.isEmpty else { return }
          await send(.livenessSweepResult(snapshot: snapshot, alive: alive))
        }

      case .livenessSweepResult(let snapshot, let alive):
        let changed = Self.applyLiveness(delta: alive, snapshot: snapshot, into: &state)
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

      case .restoreFromSnapshot(let staged):
        guard !staged.isEmpty else { return .none }
        return .run { send in
          let checked = staged.compactMapValues { stage -> RestoredRecord? in
            let alive = stage.pids.filter { Self.isAlive($0) }
            guard !alive.isEmpty else { return nil }
            return RestoredRecord(alivePids: alive, activity: stage.activity)
          }
          guard !checked.isEmpty else { return }
          await send(.restoreFromSnapshotChecked(records: checked))
        }

      case .restoreFromSnapshotChecked(let records):
        let changed = Self.applyRestore(records: records, into: &state)
        return Self.surfacesChangedEffect(changed)
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

  /// Pure liveness check; returns only keys whose alive subset diverges from the snapshot.
  nonisolated static func liveness(forSnapshot snapshot: [PresenceKey: Set<pid_t>]) -> [PresenceKey: Set<pid_t>] {
    var result: [PresenceKey: Set<pid_t>] = [:]
    for (key, pids) in snapshot {
      // `kill(0, 0)` / `kill(-N, 0)` succeed against the caller's process group; reject non-positive pids.
      let alive = pids.filter { $0 > 0 && kill($0, 0) == 0 }
      if alive != pids {
        result[key] = alive
      }
    }
    return result
  }

  /// Apply the liveness delta back to state. Pids added between snapshot capture and apply
  /// (e.g. a `.sessionStart` that landed during the off-main hop) are preserved.
  private static func applyLiveness(
    delta: [PresenceKey: Set<pid_t>],
    snapshot: [PresenceKey: Set<pid_t>],
    into state: inout State
  ) -> Set<UUID> {
    var dirtySurfaces: Set<UUID> = []
    for (key, alive) in delta {
      guard var record = state.records[key] else { continue }
      let snapshotPids = snapshot[key] ?? []
      // Subtract only the pids the sweep proved dead; current additions/removals stay authoritative.
      let deadPids = snapshotPids.subtracting(alive)
      let next = record.pids.subtracting(deadPids)
      if next.isEmpty {
        state.records.removeValue(forKey: key)
        dirtySurfaces.insert(key.surfaceID)
      } else if record.pids != next {
        record.pids = next
        state.records[key] = record
        dirtySurfaces.insert(key.surfaceID)
      }
    }
    for surfaceID in dirtySurfaces { rebuildPresence(forSurface: surfaceID, in: &state) }
    return dirtySurfaces
  }

  struct StagedRestore: Sendable {
    let pids: Set<pid_t>
    let activity: Activity
  }

  /// Build the staged-restore dict from persisted layouts. No `kill(2)` here;
  /// liveness check is the caller's responsibility in `.run`.
  nonisolated static func stageRestore(
    fromLayouts layouts: some Sequence<TerminalLayoutSnapshot>
  ) -> [PresenceKey: StagedRestore] {
    var staged: [PresenceKey: StagedRestore] = [:]
    for layout in layouts {
      for (surfaceID, records) in layout.allAgentRecords() {
        for record in records {
          guard let agent = SkillAgent(rawValue: record.agent) else { continue }
          let pids = Set(record.pids.filter { $0 > 0 })
          guard !pids.isEmpty else { continue }
          let activity = Activity(rawValue: record.activity) ?? .idle
          staged[PresenceKey(agent: agent, surfaceID: surfaceID)] =
            StagedRestore(pids: pids, activity: activity)
        }
      }
    }
    return staged
  }

  /// Rejects non-positive pids; `kill(0, ...)` targets process groups, not
  /// individual processes.
  nonisolated static func isAlive(_ pid: pid_t) -> Bool {
    pid > 0 && kill(pid, 0) == 0
  }

  /// A hook event that raced ahead of the restore takes precedence.
  private static func applyRestore(
    records: [PresenceKey: RestoredRecord],
    into state: inout State
  ) -> Set<UUID> {
    var dirtySurfaces: Set<UUID> = []
    for (key, record) in records {
      if state.records[key] != nil { continue }
      state.records[key] = PresenceRecord(activity: record.activity, pids: record.alivePids)
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
  /// Sorted output so the persisted JSON stays diff-stable.
  func agentsBySurface() -> [UUID: [TerminalLayoutSnapshot.SurfaceAgentRecord]] {
    guard !records.isEmpty else { return [:] }
    var result: [UUID: [TerminalLayoutSnapshot.SurfaceAgentRecord]] = [:]
    for (key, record) in records {
      let entry = TerminalLayoutSnapshot.SurfaceAgentRecord(
        agent: key.agent.rawValue,
        pids: record.pids.sorted(),
        activity: record.activity.rawValue
      )
      result[key.surfaceID, default: []].append(entry)
    }
    for (id, entries) in result {
      result[id] = entries.sorted { $0.agent < $1.agent }
    }
    return result
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
