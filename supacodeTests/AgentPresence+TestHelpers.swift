import ComposableArchitecture
import Foundation

@testable import supacode

/// Test-only harness around an `AgentPresenceFeature.State`. Drains the
/// manager's event stream and routes `agentHookEventReceived` /
/// `surfacesClosed` events into the reducer so callers can drive the manager
/// via `server.onEvent(...)` and then await `harness.drain()` to settle
/// presence on the same loop tick.
@MainActor
final class PresenceTestHarness {
  var state = AgentPresenceFeature.State()
  private let reducer = AgentPresenceFeature()
  private var continuation: AsyncStream<TerminalClient.Event>.Continuation?
  private var stream: AsyncStream<TerminalClient.Event>?
  private var consumeTask: Task<Void, Never>?

  func send(_ action: AgentPresenceFeature.Action) {
    _ = reducer.reduce(into: &state, action: action)
  }

  /// Inlines the off-main liveness check so tests can settle the sweep in one tick.
  func livenessSweep() {
    let snapshot: [AgentPresenceFeature.PresenceKey: Set<pid_t>] = state.records
      .compactMapValues { record in record.pids.isEmpty ? nil : record.pids }
    let alive = AgentPresenceFeature.liveness(forSnapshot: snapshot)
    guard !alive.isEmpty else { return }
    send(.livenessSweepResult(snapshot: snapshot, alive: alive))
  }

  /// Pumps any events buffered on the manager's stream into the reducer and
  /// returns. Tests call this after `server.onEvent(...)` so presence state
  /// settles before assertions.
  func drain() async {
    // Yield repeatedly so the consume task drains every buffered event before
    // returning to the test thread.
    for _ in 0..<16 { await Task.yield() }
  }

  func attach(to manager: WorktreeTerminalManager) {
    let stream = manager.eventStream()
    self.stream = stream
    consumeTask?.cancel()
    consumeTask = Task {
      for await event in stream {
        switch event {
        case .agentHookEventReceived(let payload):
          self.send(.hookEventReceived(payload))
        case .surfacesClosed(let ids):
          if ids.count == 1, let id = ids.first {
            self.send(.surfaceClosed(id))
          } else {
            self.send(.surfacesClosed(ids))
          }
        default:
          continue
        }
      }
    }
  }
}

extension WorktreeTerminalManager {
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
