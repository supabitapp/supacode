import ComposableArchitecture
import Foundation
import SwiftUI
import Testing

@testable import supacode

@MainActor
@Suite(.serialized)
struct RepositoryCustomizationFeatureTests {
  private func makeState(
    title: String = "",
    color: RepositoryColor? = nil,
  ) -> RepositoryCustomizationFeature.State {
    RepositoryCustomizationFeature.State(
      repositoryID: "/tmp/repo",
      defaultName: "repo",
      title: title,
      color: color,
      customColor: color?.color ?? .accentColor,
    )
  }

  @Test func saveTrimsTitleAndForwardsValues() async {
    let store = TestStore(initialState: makeState(title: "  Custom Title  ", color: .blue)) {
      RepositoryCustomizationFeature()
    }

    await store.send(.saveButtonTapped)
    await store.receive(
      .delegate(
        .save(repositoryID: "/tmp/repo", title: "Custom Title", color: .blue),
      ))
  }

  @Test func saveDropsTitleWhenEmptyOrMatchesDefault() async {
    let store = TestStore(initialState: makeState(title: "  repo  ")) {
      RepositoryCustomizationFeature()
    }

    await store.send(.saveButtonTapped)
    await store.receive(
      .delegate(.save(repositoryID: "/tmp/repo", title: nil, color: nil)),
    )
  }

  @Test func selectColorMirrorsCustomColor() async {
    let store = TestStore(initialState: makeState()) {
      RepositoryCustomizationFeature()
    }

    await store.send(.selectColor(.red)) {
      $0.color = .red
      $0.customColor = RepositoryColor.red.color
    }
  }

  @Test func selectNilColorClearsTint() async {
    let store = TestStore(initialState: makeState(color: .green)) {
      RepositoryCustomizationFeature()
    }

    await store.send(.selectColor(nil)) {
      $0.color = nil
    }
  }

  @Test func cancelDelegatesCancel() async {
    let store = TestStore(initialState: makeState()) {
      RepositoryCustomizationFeature()
    }

    await store.send(.cancelButtonTapped)
    await store.receive(.delegate(.cancel))
  }

  // MARK: - C2 / C6 binding-promotion contract

  @Test func bindingDoesNotDemotePredefinedToCustomHex() async {
    // The user picked `.red` from the predefined swatches; the
    // mirror in `state.customColor` is `Color.red`. A stray
    // ColorPicker write-back (sRGB-quantization round-trip) must
    // NOT promote `state.color` to `.custom("#FF…")`. The reducer
    // gates the binding arm on `isCustom == true` to enforce this.
    var initial = makeState(color: .red)
    initial.customColor = RepositoryColor.red.color
    let store = TestStore(initialState: initial) {
      RepositoryCustomizationFeature()
    }

    let quantized = Color(nsColor: .systemRed)
    await store.send(.set(\.customColor, quantized)) {
      $0.customColor = quantized
    }
    // No follow-up state mutation — `.color` stays `.red`.
  }

  @Test func selectCustomColorEntersCustomMode() async {
    // Tapping the rainbow swatch is the explicit entry path into
    // custom mode. The action promotes `state.color` to a `.custom`
    // hex derived from the current `customColor`, so subsequent
    // ColorPicker drags drive `state.color` through the binding
    // path that's gated on `isCustom`.
    let store = TestStore(initialState: makeState()) {
      RepositoryCustomizationFeature()
    }

    await store.send(.selectCustomColor) {
      $0.color = RepositoryColor.custom(from: .accentColor)
    }
  }

  @Test func bindingPromotesCustomColorWhenAlreadyInCustomMode() async {
    // Once the user is in custom mode, ColorPicker drags update
    // `state.color` through the binding arm — the gate lets the
    // promotion through because `isCustom` is already true.
    var initial = makeState(color: .custom("#112233"))
    initial.customColor = Color(
      nsColor: NSColor(srgbRed: 0x11 / 255, green: 0x22 / 255, blue: 0x33 / 255, alpha: 1),
    )
    let store = TestStore(initialState: initial) {
      RepositoryCustomizationFeature()
    }

    let next = Color(nsColor: NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
    await store.send(.set(\.customColor, next)) {
      $0.customColor = next
      $0.color = RepositoryColor.custom(from: next)
    }
  }
}
