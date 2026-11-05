import ComposableArchitecture
import Darwin
import Foundation
import Sharing
import SupacodeSettingsShared

@Reducer
struct AgentPresenceFeature {
  /// Activity state per (surface, agent), set atomically by the wire events.
  /// Canonical lifecycle for the two attention states:
  ///
  /// - `error`: the turn died, so no `idle` ever follows it. Sticky, and only
  ///   `busy` (a new turn), `sessionStart` (a restart), or `clearAttention`
  ///   (the user focused the surface) may leave it. Any other event is dropped,
  ///   or Claude's 60s-idle `Notification` would quietly downgrade it.
  /// - `compacting`: transient, cleared by the turn's next event or by the
  ///   `sessionStart` Claude fires once compaction finishes.
  enum Activity: String, Sendable, Equatable {
    case awaitingInput
    case busy
    case idle
    case error
    case compacting

    /// Counts as the agent working: the row shimmers. Compaction happens inside a
    /// running turn, so it must not read as a stalled agent.
    var isWorking: Bool { self == .busy || self == .compacting }

    /// Parked on the user, so focusing the surface answers it.
    var isAttention: Bool { self == .error || self == .awaitingInput }

    /// The badge state for an OSC 7501 report. `done` is idle with an unread
    /// result, which the notification carries. Nil for `clear`, which is not a state.
    init?(programStatus state: ProgramStatusReport.State) {
      switch state {
      case .idle, .done: self = .idle
      case .working: self = .busy
      case .blocked: self = .awaitingInput
      case .error: self = .error
      case .clear: return nil
      }
    }
  }

  /// One badge worth of state. Surface ID is redundant; callers scope by surface set.
  struct AgentInstance: Hashable, Sendable {
    let agent: SkillAgent
    let activity: Activity

    /// The avatar group flips contrast on awaiting-input instances.
    var awaitingInput: Bool { activity == .awaitingInput }
  }

  /// Everything one sidebar row shows about its agents, fanned out as a single
  /// value so a new flag doesn't grow the action or its dirty check. Compaction
  /// needs no entry: the badge carries it, and the row treats it as work.
  struct RowSnapshot: Equatable, Sendable {
    var agents: [AgentInstance] = []
    var isWorking = false
    var hasError = false
  }

  // `nonisolated` so `stageRestore` (off-main at launch) can use Hashable.
  nonisolated struct PresenceKey: Hashable, Sendable {
    let agent: SkillAgent
    let surfaceID: UUID
  }

  /// Where a record's state comes from. A hook record follows the hook event
  /// lifecycle; a program status record follows OSC 7501, where each report
  /// replaces the record whole and `clear` or a returning prompt ends it.
  nonisolated enum Source: String, Equatable, Sendable {
    case hook
    case programStatus = "program_status"
  }

  nonisolated struct PresenceRecord: Equatable, Sendable {
    var activity: Activity = .idle
    /// Local pids attributed to this record. Empty means the OSC presence was
    /// emitted without a local pid (SSH attach); `pids.isEmpty` is the
    /// discriminator for the pid-less lifecycle branches below. Every event
    /// arrives over OSC now, so there is no "socket-owned" record to defend
    /// against.
    var pids: Set<pid_t>
    var source: Source = .hook
  }

  nonisolated struct RestoredRecord: Sendable {
    let alivePids: Set<pid_t>
    let activity: Activity
    var source: Source = .hook
  }

  // `nonisolated` is load-bearing here. Without it the @Reducer macro
  // propagates main-actor isolation onto CancelID's Hashable witness, which
  // then can't satisfy the Sendable requirement in `.cancellable(id:)`.
  nonisolated enum CancelID: Hashable, Sendable { case livenessSweep }

  enum Action {
    case delegate(Delegate)
    case hookEventReceived(AgentHookEvent)
    /// An OSC 7501 report. Only the root record drives a badge.
    case programStatusReceived(surfaceID: UUID, report: ProgramStatusReport)
    /// A shell prompt came back on the surface, which ends its `working` and
    /// `blocked` program status records.
    case programStatusPromptReturned(surfaceID: UUID)
    case livenessSweepTick
    case livenessSweepResult(snapshot: [PresenceKey: Set<pid_t>], alive: [PresenceKey: Set<pid_t>])
    case start
    case stop
    case surfaceClosed(UUID)
    case surfacesClosed(Set<UUID>)
    /// The user focused these surfaces, so the states parked on them (`error`,
    /// `awaitingInput`) return to `idle`.
    case clearAttention(surfaces: Set<UUID>)
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
    /// disposal. Socket bridges carry a pid; the OSC-over-SSH transport seeds
    /// pid-less records that the sweep skips.
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
      @Dependency(\.zmxClient) var zmxClient
      switch action {
      case .delegate:
        return .none

      case .hookEventReceived(let event):
        let changed = Self.apply(event: event, into: &state)
        return Self.surfacesChangedEffect(changed)

      case .programStatusReceived(let surfaceID, let report):
        let changed = Self.apply(programStatus: report, surfaceID: surfaceID, into: &state)
        return Self.surfacesChangedEffect(changed)

      case .programStatusPromptReturned(let surfaceID):
        let changed = Self.endTransientProgramStatus(onSurface: surfaceID, into: &state)
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

      case .clearAttention(let surfaces):
        let changed = Self.clearAttention(on: surfaces, into: &state)
        return Self.surfacesChangedEffect(changed)

      case .restoreFromSnapshot(let staged):
        guard !staged.isEmpty else { return .none }
        return .run { send in
          let liveSessions: Set<String>
          if staged.values.contains(where: { $0.source == .programStatus }) {
            liveSessions = Set(await zmxClient.listSessionsWithClients()?.map(\.name) ?? [])
          } else {
            liveSessions = []
          }
          let checked = Self.checkRestore(staged: staged, liveSessions: liveSessions)
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
      return applySessionStart(event: event, key: key, into: &state)
    case .sessionEnd:
      if let pid = event.pid {
        guard var record = state.records[key] else { return [] }
        let removed = record.pids.remove(pid) != nil
        if record.pids.isEmpty {
          state.records.removeValue(forKey: key)
        } else {
          state.records[key] = record
        }
        rebuildPresence(forSurface: event.surfaceID, in: &state)
        return removed ? [event.surfaceID] : []
      }
      // Pid-less (OSC over SSH): only tear down a pid-less record; never one
      // that carries a tracked local pid the liveness sweep still owns.
      guard let record = state.records[key], record.pids.isEmpty else { return [] }
      state.records.removeValue(forKey: key)
      rebuildPresence(forSurface: event.surfaceID, in: &state)
      return [event.surfaceID]
    case .busy:
      return applyActivity(.busy, event: event, key: key, into: &state) ? [event.surfaceID] : []
    case .awaitingInput:
      return applyActivity(.awaitingInput, event: event, key: key, into: &state) ? [event.surfaceID] : []
    case .idle:
      return applyActivity(.idle, event: event, key: key, into: &state) ? [event.surfaceID] : []
    case .error:
      return applyActivity(.error, event: event, key: key, into: &state) ? [event.surfaceID] : []
    case .compacting:
      return applyActivity(.compacting, event: event, key: key, into: &state) ? [event.surfaceID] : []
    case .notification, .none:
      return []
    }
  }

  /// Applies one OSC 7501 report. The root record names the agent through `app`
  /// and becomes its badge; a root `clear` removes every program status record
  /// on the surface, as a `clear` without an id removes every record. Child
  /// records carry no badge of their own.
  private static func apply(
    programStatus report: ProgramStatusReport, surfaceID: UUID, into state: inout State
  ) -> Set<UUID> {
    guard report.isRoot else { return [] }
    guard report.state != .clear else {
      let keys = state.records.filter { $0.key.surfaceID == surfaceID && $0.value.source == .programStatus }.keys
      guard !keys.isEmpty else { return [] }
      for key in keys { state.records.removeValue(forKey: key) }
      rebuildPresence(forSurface: surfaceID, in: &state)
      return [surfaceID]
    }
    guard let agent = report.agent, let activity = Activity(programStatus: report.state) else { return [] }
    let key = PresenceKey(agent: agent, surfaceID: surfaceID)
    let existing = state.records[key]
    var record = existing ?? PresenceRecord(pids: [])
    record.activity = activity
    record.source = .programStatus
    guard record != existing else { return [] }
    state.records[key] = record
    if existing == nil { rebuildPresence(forSurface: surfaceID, in: &state) }
    return [surfaceID]
  }

  /// The specification ends `working` and `blocked` records when a new shell
  /// prompt begins; `idle`, `done`, and `error` survive. A record that also
  /// carries a hook pid stays for the liveness sweep and only drops to idle.
  private static func endTransientProgramStatus(onSurface surfaceID: UUID, into state: inout State) -> Set<UUID> {
    let transient = state.records.filter { entry in
      entry.key.surfaceID == surfaceID && entry.value.source == .programStatus
        && (entry.value.activity == .busy || entry.value.activity == .awaitingInput)
    }
    guard !transient.isEmpty else { return [] }
    for (key, record) in transient {
      if record.pids.isEmpty {
        state.records.removeValue(forKey: key)
      } else {
        state.records[key]?.activity = .idle
      }
    }
    rebuildPresence(forSurface: surfaceID, in: &state)
    return [surfaceID]
  }

  /// A pid is the local-hook source (OSC presence carries `pid=$__ppid` only on the
  /// local host); a missing pid is the OSC-over-SSH source, which attributes by the
  /// receiving surface and has no local pid to track. Either way the restart clears
  /// a sticky state, or an SSH session that errored would never recover.
  private static func applySessionStart(
    event: AgentHookEvent, key: PresenceKey, into state: inout State
  ) -> Set<UUID> {
    if let pid = event.pid {
      var record = state.records[key] ?? PresenceRecord(pids: [])
      let inserted = record.pids.insert(pid).inserted
      let cleared = Self.normalizeStickyOnRestart(&record)
      state.records[key] = record
      rebuildPresence(forSurface: event.surfaceID, in: &state)
      return (inserted || cleared) ? [event.surfaceID] : []
    }
    // Pid-less OSC seed: don't clobber a record that already carries a pid.
    guard var record = state.records[key] else {
      state.records[key] = PresenceRecord(pids: [])
      rebuildPresence(forSurface: event.surfaceID, in: &state)
      return [event.surfaceID]
    }
    guard Self.normalizeStickyOnRestart(&record) else { return [] }
    state.records[key] = record
    rebuildPresence(forSurface: event.surfaceID, in: &state)
    return [event.surfaceID]
  }

  /// Resets a sticky `error` / `compacting` record to `idle` on a restart.
  /// Returns whether it changed anything.
  private static func normalizeStickyOnRestart(_ record: inout PresenceRecord) -> Bool {
    guard record.activity == .error || record.activity == .compacting else { return false }
    record.activity = .idle
    return true
  }

  /// Resets the states parked on the user (`error`, `awaitingInput`) to `idle`
  /// on the surfaces they focused. Returns the surfaces whose record flipped.
  private static func clearAttention(on surfaces: Set<UUID>, into state: inout State) -> Set<UUID> {
    var changed: Set<UUID> = []
    for (key, record) in state.records
    where surfaces.contains(key.surfaceID) && record.activity.isAttention {
      var updated = record
      updated.activity = .idle
      state.records[key] = updated
      changed.insert(key.surfaceID)
    }
    return changed
  }

  /// Auto-seed only on the OSC path (pid == nil), and only when the activity
  /// would actually carry a badge: SSH attach can land on `busy` /
  /// `awaiting_input` with no prior `session_start`, but an `idle` arriving
  /// after the `session_end` + `idle` composite shutdown emit must NOT
  /// re-create the record. A pid-less idle re-seed would be skipped by the
  /// liveness sweep and pinned until surface close. Hermes is the exception:
  /// its per-turn `on_session_end` emits idle only (no `session_end`), so over
  /// SSH its badge clears on surface close rather than at process exit.
  private static func applyActivity(
    _ activity: Activity, event: AgentHookEvent, key: PresenceKey, into state: inout State
  ) -> Bool {
    if var record = state.records[key] {
      guard record.activity != activity else { return false }
      // A dead turn stays dead: only a new turn (`busy`) may overwrite `error`.
      // Claude's 60s-idle `Notification` fires `awaitingInput` on exactly the
      // session that just died, and would otherwise downgrade it to "waiting".
      guard record.activity != .error || activity == .busy else { return false }
      record.activity = activity
      state.records[key] = record
      return true
    }
    guard event.pid == nil, activity != .idle else { return false }
    state.records[key] = PresenceRecord(activity: activity, pids: [])
    rebuildPresence(forSurface: event.surfaceID, in: &state)
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
      let alive = pids.filter { isAlive($0) }
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
    var source: Source = .hook
  }

  /// Build the staged-restore dict from the persisted v2 layouts file. No
  /// `kill(2)` here; liveness check is the caller's responsibility in `.run`.
  nonisolated static func stageRestore(from file: LayoutsFile) -> [PresenceKey: StagedRestore] {
    stageRestore(fromAgentRecords: file.worktrees.values.map { $0.layout.allAgentRecords() })
  }

  /// Build the staged-restore dict from persisted layouts. No `kill(2)` here;
  /// liveness check is the caller's responsibility in `.run`.
  nonisolated static func stageRestore(
    fromLayouts layouts: some Sequence<TerminalLayoutSnapshot>
  ) -> [PresenceKey: StagedRestore] {
    stageRestore(fromAgentRecords: layouts.map { $0.allAgentRecords() })
  }

  private nonisolated static func stageRestore(
    fromAgentRecords all: [[(surfaceID: UUID, records: [TerminalLayoutSnapshot.SurfaceAgentRecord])]]
  ) -> [PresenceKey: StagedRestore] {
    var staged: [PresenceKey: StagedRestore] = [:]
    for layout in all {
      for (surfaceID, records) in layout {
        for record in records {
          guard let agent = SkillAgent(rawValue: record.agent) else { continue }
          let key = PresenceKey(agent: agent, surfaceID: surfaceID)
          let pids = Set(record.pids.filter { $0 > 0 })
          // A program reports on change only, so a reattached session stays
          // silent until its next change: keep the record. `working` and
          // `blocked` may have ended while the app was closed, so they come back
          // as idle; `error` survives a prompt per the specification.
          if record.source == Source.programStatus.rawValue {
            let restored = Activity(rawValue: record.activity) == .error ? Activity.error : .idle
            staged[key] = StagedRestore(pids: pids, activity: restored, source: .programStatus)
            continue
          }
          // Pid-less hook OSC records aren't restore-durable: they persist with no
          // pid, so they drop here and re-seed on the next OSC event post-relaunch.
          guard !pids.isEmpty else { continue }
          let activity = Activity(rawValue: record.activity) ?? .idle
          staged[key] = StagedRestore(pids: pids, activity: activity)
        }
      }
    }
    return staged
  }

  /// Keeps a hook record whose pids are still alive, and a program status record
  /// whose zmx session survived. Program status has no pid, so the session is the
  /// liveness signal: one that didn't survive (a reboot) restarts its shell, and
  /// the program that reported is gone. An unknown listing restores none of them.
  nonisolated static func checkRestore(
    staged: [PresenceKey: StagedRestore],
    liveSessions: Set<String>
  ) -> [PresenceKey: RestoredRecord] {
    var checked: [PresenceKey: RestoredRecord] = [:]
    for (key, stage) in staged {
      if stage.source == .programStatus {
        guard liveSessions.contains(ZmxSessionID.make(surfaceID: key.surfaceID)) else { continue }
        checked[key] = RestoredRecord(alivePids: [], activity: stage.activity, source: .programStatus)
        continue
      }
      let alive = stage.pids.filter { isAlive($0) }
      guard !alive.isEmpty else { continue }
      checked[key] = RestoredRecord(alivePids: alive, activity: stage.activity)
    }
    return checked
  }

  /// Rejects non-positive pids; `kill(0, ...)` targets process groups, not
  /// individual processes. Treats EPERM as alive (sandboxes deny signaling
  /// live processes) and anything else as dead. Mirrors `ProcessLiveness.isRunning`.
  nonisolated static func isAlive(_ pid: pid_t) -> Bool {
    guard pid > 0 else { return false }
    let probeSucceeded = kill(pid, 0) == 0
    // Capture errno immediately so a future edit cannot clobber it first.
    let probeErrno = errno
    return probeSucceeded || probeErrno == EPERM
  }

  /// A hook event that raced ahead of the restore takes precedence.
  private static func applyRestore(
    records: [PresenceKey: RestoredRecord],
    into state: inout State
  ) -> Set<UUID> {
    var dirtySurfaces: Set<UUID> = []
    for (key, record) in records {
      if state.records[key] != nil { continue }
      // Restored hook records always have alive pids (pid-less hook OSC records
      // are dropped in stageRestore); program status records carry none.
      state.records[key] = PresenceRecord(activity: record.activity, pids: record.alivePids, source: record.source)
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
        activity: record.activity.rawValue,
        source: record.source == .programStatus ? record.source.rawValue : nil
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
  /// Duplicates preserved (a tab hosting two surfaces both running Claude shows
  /// two Claude badges). Sorted error-first, then awaiting-input, then by agent
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
        let lhsError = lhs.activity == .error
        let rhsError = rhs.activity == .error
        if lhsError != rhsError { return lhsError }
        if lhs.awaitingInput != rhs.awaitingInput { return lhs.awaitingInput }
        return lhs.agent.rawValue < rhs.agent.rawValue
      }
  }

  /// The badge lineup and the aggregates a sidebar row derives from it, in a
  /// single pass over `records`. The error is carried by the badge itself, so it
  /// only surfaces when badges are on; the shimmer is a generic "this worktree is
  /// doing work" signal and stays independent of the toggle.
  func rowSnapshot(
    across surfaceIDs: some Sequence<UUID>,
    badgesEnabled: Bool,
  ) -> AgentPresenceFeature.RowSnapshot {
    let surfaceSet = Set(surfaceIDs)
    var isWorking = false
    var hasError = false
    for (key, record) in records where surfaceSet.contains(key.surfaceID) {
      if record.activity.isWorking { isWorking = true }
      if record.activity == .error, badgesEnabled { hasError = true }
    }
    return AgentPresenceFeature.RowSnapshot(
      agents: agents(across: surfaceSet, badgesEnabled: badgesEnabled),
      isWorking: isWorking,
      hasError: hasError
    )
  }

  /// Any agent on the listed surfaces is working (`busy`, or compacting inside a
  /// running turn). Awaiting-input is excluded: the agent is parked on the user,
  /// so it must not shimmer. Not gated by the badge toggle.
  func hasActivity(in surfaceIDs: some Sequence<UUID>) -> Bool {
    let surfaceSet = Set(surfaceIDs)
    return records.contains { entry in
      entry.value.activity.isWorking && surfaceSet.contains(entry.key.surfaceID)
    }
  }

  /// Any agent on the listed surfaces ended its turn in an API error.
  func hasError(in surfaceIDs: some Sequence<UUID>) -> Bool {
    let surfaceSet = Set(surfaceIDs)
    return records.contains { entry in
      entry.value.activity == .error && surfaceSet.contains(entry.key.surfaceID)
    }
  }

  /// Any agent on the listed surfaces is compacting its context.
  func isCompacting(in surfaceIDs: some Sequence<UUID>) -> Bool {
    let surfaceSet = Set(surfaceIDs)
    return records.contains { entry in
      entry.value.activity == .compacting && surfaceSet.contains(entry.key.surfaceID)
    }
  }
}
