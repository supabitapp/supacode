import AppKit
import SwiftUI
import Testing

@testable import supacode

@MainActor
struct SurfaceChromeAppearanceTests {
  @Test func overlayTintIsWhiteInDarkScheme() {
    let appearance = SurfaceChromeAppearance(colorScheme: .dark, systemColorScheme: .dark)
    #expect(appearance.overlayTint == .white)
  }

  @Test func overlayTintIsBlackInLightScheme() {
    let appearance = SurfaceChromeAppearance(colorScheme: .light, systemColorScheme: .dark)
    #expect(appearance.overlayTint == .black)
  }

  @Test func separatorOpacityIsHigherInDarkScheme() {
    let dark = SurfaceChromeAppearance(colorScheme: .dark, systemColorScheme: .dark)
    let light = SurfaceChromeAppearance(colorScheme: .light, systemColorScheme: .light)
    #expect(dark.separatorOpacity == 0.22)
    #expect(light.separatorOpacity == 0.14)
  }

  @Test func equalityComparesBothSchemes() {
    let original = SurfaceChromeAppearance(colorScheme: .dark, systemColorScheme: .light)
    let same = SurfaceChromeAppearance(colorScheme: .dark, systemColorScheme: .light)
    let different = SurfaceChromeAppearance(colorScheme: .dark, systemColorScheme: .dark)
    #expect(original == same)
    #expect(original != different)
  }
}

@MainActor
struct WindowAppearanceStateTests {
  @Test func equalStatesDedupe() {
    let lhs = WindowAppearanceState(
      opacity: 0.7,
      appearance: .aqua,
      isFullScreen: false,
      isOpaqueOverride: false
    )
    let rhs = WindowAppearanceState(
      opacity: 0.7,
      appearance: .aqua,
      isFullScreen: false,
      isOpaqueOverride: false
    )
    #expect(lhs == rhs)
  }

  @Test func opacityChangeBreaksEquality() {
    let lhs = WindowAppearanceState(opacity: 1, appearance: .aqua, isFullScreen: false, isOpaqueOverride: false)
    let rhs = WindowAppearanceState(opacity: 0, appearance: .aqua, isFullScreen: false, isOpaqueOverride: false)
    #expect(lhs != rhs)
  }

  @Test func appearanceChangeBreaksEquality() {
    let lhs = WindowAppearanceState(opacity: 0.7, appearance: .aqua, isFullScreen: false, isOpaqueOverride: false)
    let rhs = WindowAppearanceState(opacity: 0.7, appearance: .darkAqua, isFullScreen: false, isOpaqueOverride: false)
    #expect(lhs != rhs)
  }

  @Test func fullScreenChangeBreaksEquality() {
    let lhs = WindowAppearanceState(opacity: 0.7, appearance: .aqua, isFullScreen: false, isOpaqueOverride: false)
    let rhs = WindowAppearanceState(opacity: 0.7, appearance: .aqua, isFullScreen: true, isOpaqueOverride: false)
    #expect(lhs != rhs)
  }

  @Test func opaqueOverrideChangeBreaksEquality() {
    let lhs = WindowAppearanceState(opacity: 0.7, appearance: .aqua, isFullScreen: false, isOpaqueOverride: false)
    let rhs = WindowAppearanceState(opacity: 0.7, appearance: .aqua, isFullScreen: false, isOpaqueOverride: true)
    #expect(lhs != rhs)
  }
}
