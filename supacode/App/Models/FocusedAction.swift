import SwiftUI

/// Equatable wrapper around a focused-value action closure.
///
/// SwiftUI's `focusedSceneValue` / `focusedValue` re-publishes whenever the
/// stored value's identity changes. A bare `() -> Void` closure has no
/// Equatable conformance, so every publisher-view body run looks like a
/// "value changed" event to AppKit, which then rebuilds the system menu and
/// drops open-submenu / hover state (#289). Wrapping the closure in this
/// Equatable adapter keeps the focused value stable across no-op body runs.
///
/// **Contract**: `token` must hash any captured state that affects the
/// closure's behavior. If the closure captures only stable references
/// (the store, projected `@State` bindings), `token` can stay `nil`. If it
/// captures a list of targets, an alert payload, etc., set `token` to a
/// hashable projection of those values so a real change triggers a republish.
struct FocusedAction<Input>: Equatable {
  let isEnabled: Bool
  let token: AnyHashable?
  private let perform: (Input) -> Void

  init(
    isEnabled: Bool,
    token: AnyHashable? = nil,
    perform: @escaping (Input) -> Void
  ) {
    self.isEnabled = isEnabled
    self.token = token
    self.perform = perform
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.isEnabled == rhs.isEnabled && lhs.token == rhs.token
  }

  func callAsFunction(_ input: Input) {
    guard isEnabled else { return }
    perform(input)
  }
}

extension FocusedAction where Input == Void {
  func callAsFunction() {
    callAsFunction(())
  }
}

extension View {
  /// Publishes a stable `FocusedAction` through `focusedSceneValue`.
  /// Prefer this over a raw closure: AppKit only sees a "value changed"
  /// event when `enabled` or `token` flip, instead of on every body run.
  func focusedSceneAction<Input>(
    _ keyPath: WritableKeyPath<FocusedValues, FocusedAction<Input>?>,
    enabled: Bool,
    token: AnyHashable? = nil,
    perform: @escaping (Input) -> Void
  ) -> some View {
    focusedSceneValue(
      keyPath,
      FocusedAction(isEnabled: enabled, token: token, perform: perform)
    )
  }

  /// `focusedValue` variant. Same contract as `focusedSceneAction`.
  func focusedAction<Input>(
    _ keyPath: WritableKeyPath<FocusedValues, FocusedAction<Input>?>,
    enabled: Bool,
    token: AnyHashable? = nil,
    perform: @escaping (Input) -> Void
  ) -> some View {
    focusedValue(
      keyPath,
      FocusedAction(isEnabled: enabled, token: token, perform: perform)
    )
  }
}
