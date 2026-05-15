import ComposableArchitecture
import Foundation

@testable import supacode

/// Test-only harness that runs a private `AgentPresenceFeature.State` and pumps
/// presence deltas (`surfaceClosed`, `surfacesClosed`, `hookEventReceived`,
/// `livenessSweepTick`) back into the `WorktreeTerminalManager` the same way
/// `AppFeature` does in production: drain the manager's event stream and
/// translate `surfacesClosed` / `agentHookEventReceived` events into reducer
/// dispatches. After each dispatch the harness pushes the authoritative busy
/// surface set into the manager via `.agentActivityChanged`.
@MainActor
final class PresenceTestHarness {
  var state = AgentPresenceFeature.State()
  private let reducer = AgentPresenceFeature()
  private weak var manager: WorktreeTerminalManager?
  private var eventTask: Task<Void, Never>?

  func send(_ action: AgentPresenceFeature.Action) {
    let dirtyBefore = busySurfaceIDs()
    _ = reducer.reduce(into: &state, action: action)
    let dirtyAfter = busySurfaceIDs()
    let dirty = dirtyBefore.symmetricDifference(dirtyAfter)
    manager?.handleAgentActivityChanged(busySurfaceIDs: dirtyAfter, dirtySurfaceIDs: dirty)
  }

  func attach(to manager: WorktreeTerminalManager) {
    self.manager = manager
    // Strong captures: tests routinely discard the harness with `_`, which
    // would nil out a weak capture before the first hook event arrived.
    manager.syncPresenceBridge = { event in
      _ = self.reducer.reduce(into: &self.state, action: .hookEventReceived(event))
      return self.busySurfaceIDs()
    }
    let stream = manager.eventStream()
    eventTask?.cancel()
    eventTask = Task {
      for await event in stream {
        if case .surfacesClosed(let ids) = event {
          if ids.count == 1, let id = ids.first {
            self.send(.surfaceClosed(id))
          } else {
            self.send(.surfacesClosed(ids))
          }
        }
      }
    }
  }

  func detach() {
    eventTask?.cancel()
    eventTask = nil
    manager = nil
  }

  private func busySurfaceIDs() -> Set<UUID> {
    Set(
      state.records
        .filter { $0.value.activity != .idle }
        .map(\.key.surfaceID),
    )
  }
}

extension WorktreeTerminalManager {
  /// Spins up a fresh `PresenceTestHarness` bound to a new manager. Tests get
  /// both pieces back so they can drive presence directly (`harness.send(...)`)
  /// or assert on `harness.state` without owning a TCA store.
  @MainActor static func withPresenceHarness(
    runtime: GhosttyRuntime = GhosttyRuntime(),
    socketServer: AgentHookSocketServer? = nil,
    clock: some Clock<Duration> = ContinuousClock(),
  ) -> (manager: WorktreeTerminalManager, presence: PresenceTestHarness) {
    let harness = PresenceTestHarness()
    let manager = WorktreeTerminalManager(runtime: runtime, socketServer: socketServer, clock: clock)
    harness.attach(to: manager)
    return (manager, harness)
  }
}
