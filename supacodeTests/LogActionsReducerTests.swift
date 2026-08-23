import ComposableArchitecture
import Testing

@testable import supacode

/// A minimal hand-rolled reducer (no `@Reducer` macro) so the test exercises
/// `logActions()` over a real base reduction with both a state write and an
/// effect.
private struct LogActionsCounter: Reducer {
  struct State: Equatable {
    var count = 0
    var ranEffect = false
  }
  enum Action: Equatable {
    case bump
    case effectFired
  }

  func reduce(into state: inout State, action: Action) -> Effect<Action> {
    switch action {
    case .bump:
      state.count += 1
      return .run { await $0(.effectFired) }
    case .effectFired:
      state.ranEffect = true
      return .none
    }
  }
}

/// `.logActions()` is a transparent passthrough when SUPACODE_LOG_ACTIONS is
/// unset, which is the default in every build and in the test process. It must
/// not change what the base reducer does to state or effects.
@MainActor
struct LogActionsReducerTests {
  @Test func passthroughPreservesStateMutationAndEffects() async {
    let store = TestStore(initialState: LogActionsCounter.State()) {
      LogActionsCounter().logActions()
    }
    await store.send(.bump) { $0.count = 1 }
    await store.receive(.effectFired) { $0.ranEffect = true }
  }
}
