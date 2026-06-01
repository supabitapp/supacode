import ComposableArchitecture
import Foundation

@testable import supacode

/// Test-only harness around an `AgentPresenceFeature.State`. A background task
/// drains the manager's event stream and routes `agentHookEventReceived` /
/// `surfacesClosed` events into the reducer so callers can drive the manager
/// via `server.onEvent(...)` and then await `harness.drain()` to settle
/// presence before asserting.
@MainActor
final class PresenceTestHarness {
  var state = AgentPresenceFeature.State()
  private let reducer = AgentPresenceFeature()
  private var stream: AsyncStream<TerminalClient.Event>?
  private var consumeTask: Task<Void, Never>?
  /// Bumped each time the consume task reduces a stream event.
  private var processedCount = 0
  /// Bumped each time the consume task is about to wait for the next event, i.e.
  /// it has drained everything buffered so far.
  private var parkCount = 0

  func send(_ action: AgentPresenceFeature.Action) {
    reduce(action)
  }

  private func reduce(_ action: AgentPresenceFeature.Action) {
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

  /// Settles presence after `server.onEvent(...)` / `clock.advance(...)`. Each
  /// pass runs `megaYield` (flushing the consume task plus any clock-awoken
  /// manager emit, e.g. an idle debounce resuming after `clock.advance`) and
  /// returns once the consumer has parked again with no reduction in the final
  /// pass, i.e. it observed and drained everything this call produced. The cap
  /// keeps a genuinely quiet stream from looping forever.
  func drain() async {
    guard consumeTask != nil else { return }
    var settled = 0
    for _ in 0..<64 {
      let parksBefore = parkCount
      let processedBefore = processedCount
      await Task.megaYield(count: 10_000)
      let parkedAgain = parkCount > parksBefore
      let quiet = processedCount == processedBefore
      settled = parkedAgain && quiet ? settled + 1 : 0
      if settled >= 2 { return }
    }
  }

  func attach(to manager: WorktreeTerminalManager) {
    let stream = manager.eventStream()
    self.stream = stream
    consumeTask?.cancel()
    consumeTask = Task {
      var iterator = stream.makeAsyncIterator()
      while true {
        self.parkCount += 1
        guard let event = await iterator.next() else { return }
        switch event {
        case .agentHookEventReceived(let payload):
          self.reduce(.hookEventReceived(payload))
        case .surfacesClosed(let ids):
          if ids.count == 1, let id = ids.first {
            self.reduce(.surfaceClosed(id))
          } else {
            self.reduce(.surfacesClosed(ids))
          }
        default:
          continue
        }
        self.processedCount += 1
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
