import ComposableArchitecture
import Foundation

@testable import supacode

/// Test-only wiring that connects `WorktreeTerminalManager` to a private
/// `AgentPresenceFeature.State`. The production wiring lives in
/// `supacodeApp.configureSocketHandlers`; tests construct the manager
/// directly, so the presence-closures default to `unimplemented` and would
/// fail loudly on the first hook event without this helper.
///
/// Returns both the manager and the test harness so callers can assert
/// presence state without owning a TCA store. Liveness sweeps still rely on
/// real `kill(pid, 0)` and so are driven by sending `.livenessSweepTick`
/// directly into `harness`.
@MainActor
final class PresenceTestHarness {
  var state = AgentPresenceFeature.State()
  private let reducer = AgentPresenceFeature()

  func send(_ action: AgentPresenceFeature.Action) {
    _ = reducer.reduce(into: &state, action: action)
  }
}

extension WorktreeTerminalManager {
  /// Wires a fresh `PresenceTestHarness` into a new manager. Mirrors the
  /// production wiring in `supacodeApp.configureSocketHandlers`. Badges are
  /// always enabled in this helper; tests asserting the badges-disabled gate
  /// should override `agentsForSurfaces` themselves.
  @MainActor static func withPresenceHarness(
    runtime: GhosttyRuntime = GhosttyRuntime(),
    socketServer: AgentHookSocketServer? = nil,
    clock: some Clock<Duration> = ContinuousClock(),
  ) -> (manager: WorktreeTerminalManager, presence: PresenceTestHarness) {
    let harness = PresenceTestHarness()
    let manager = WorktreeTerminalManager(runtime: runtime, socketServer: socketServer, clock: clock)
    // Strong captures here are intentional: tests routinely discard the
    // harness return with `_`, which would nil out a weak capture before the
    // first hook event arrived.
    manager.sendPresenceAction = { action in harness.send(action) }
    manager.hasAgentActivity = { surfaces in harness.state.hasActivity(in: surfaces) }
    manager.agentsForSurfaces = { surfaces in
      harness.state.agents(across: surfaces, badgesEnabled: true)
    }
    return (manager, harness)
  }
}
