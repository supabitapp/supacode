import Clocks
import ComposableArchitecture
import Foundation

@testable import SupacodeSettingsShared
@testable import supacode

/// Approximates Grok's textual preflight over a managed hook command: it scans the
/// command string for `$NAME` references and refuses to run the hook when one is not
/// in the env it forwards. So a managed command may only name a forwarded var or a
/// `__`-prefixed local the command assigns itself.
enum ManagedHookCommandVariables {
  /// Matches `$NAME` and `${NAME...}`. `$$` and awk's `$0` are excluded by the
  /// leading `[A-Za-z_]`, and `${__tty#/dev/}` captures just the name. Models the
  /// textual scan, not shell expansion, so it misses `${#NAME}`, `${!NAME}` and
  /// arithmetic `$((NAME))`; none of which belong in a hook command.
  private static let pattern = #/\$\{?([A-Za-z_][A-Za-z0-9_]*)/#

  static func names(in command: String) -> Set<String> {
    Set(command.matches(of: pattern).map { String($0.1) })
  }

  /// Names outside the allowlist, i.e. the ones that would break the preflight.
  /// The forwarded set is Grok's, applied to every agent because they share one
  /// command shape; an agent-specific env var would need its own allowlist.
  static func unexpected(in command: String) -> Set<String> {
    let forwarded = Set(AgentHookSettingsCommand.grokHookEnvPassthrough.keys)
    return names(in: command).filter { !forwarded.contains($0) && !$0.hasPrefix("__") }
  }
}

/// Test-only harness around an `AgentPresenceFeature.State`. A background task
/// drains the manager's event stream and routes `agentHookEventReceived` /
/// `surfacesClosed` events into the reducer so callers can drive the manager
/// via `state.onAgentHookEvent(...)` and then await `harness.drain()` to settle
/// presence before asserting.
@MainActor
final class PresenceTestHarness {
  var state = AgentPresenceFeature.State()
  private let reducer = AgentPresenceFeature()
  private var stream: AsyncStream<TerminalClient.Event>?
  private var consumeTask: Task<Void, Never>?
  private weak var manager: WorktreeTerminalManager?
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

  /// Settles presence after `state.onAgentHookEvent(...)` / `clock.advance(...)`. Each
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
      // Each megaYield spawns `count` detached tasks. A clock-awoken producer
      // (e.g. an idle debounce resuming after `clock.advance`) needs enough
      // yields within a single pass to resume, emit, and let the consumer
      // reduce before we sample quiescence; too few and a busy suite schedules
      // the resume after the sample, so we conclude "idle" before the idle
      // event lands. 1000 keeps the per-call cost two orders below the legacy
      // 10_000 while staying robust under contention.
      await Task.megaYield(count: 1000)
      // Quiescent when the consumer is parked, nothing processed this pass, and
      // no idle-hook debounce is still scheduled. The last clause closes the
      // race where `clock.advance` returned but the awoken idle task hasn't yet
      // emitted: its key lingers in the manager until it does, so a pending
      // count keeps draining instead of concluding "idle" too early.
      let consumerIdle = parkCount == parksBefore && processedCount == processedBefore
      let noPendingIdle = (manager?.pendingIdleHookCountForTesting ?? 0) == 0
      settled = consumerIdle && noPendingIdle ? settled + 1 : 0
      if settled >= 2 { return }
    }
  }

  /// Advances `clock` after letting any just-scheduled idle-debounce task reach
  /// and register its `clock.sleep`. A bare `clock.advance` on the line right
  /// after `state.onAgentHookEvent(.idle ...)` can otherwise run before the
  /// debounce task registers its sleeper, so the sleep is scheduled past the
  /// advanced instant and never fires (flaky under load, e.g. on CI).
  func advance(_ clock: TestClock<Duration>, by duration: Duration) async {
    await Task.megaYield(count: 1000)
    await clock.advance(by: duration)
  }

  func attach(to manager: WorktreeTerminalManager) {
    self.manager = manager
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
        case .surfacesClosed(_, let ids):
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
    surfaceBindingActionPerformer: ((GhosttySurfaceView, String) -> Void)? = nil
  ) -> (manager: WorktreeTerminalManager, presence: PresenceTestHarness) {
    let harness = PresenceTestHarness()
    let manager = WorktreeTerminalManager(
      runtime: runtime,
      socketServer: socketServer,
      clock: clock,
      surfaceBindingActionPerformer: surfaceBindingActionPerformer
    )
    harness.attach(to: manager)
    return (manager, harness)
  }
}
