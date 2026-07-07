import AppKit
import SwiftUI
import Testing

@testable import supacode

@MainActor
struct WindowAppearanceStateTests {
  @Test func equalStatesDedupe() {
    let lhs = WindowAppearanceState(
      opacity: 0.7,
      isFullScreen: false,
      isOpaqueOverride: false,
      backgroundColorKey: "26,42,58"
    )
    let rhs = WindowAppearanceState(
      opacity: 0.7,
      isFullScreen: false,
      isOpaqueOverride: false,
      backgroundColorKey: "26,42,58"
    )
    #expect(lhs == rhs)
  }

  @Test func opacityChangeBreaksEquality() {
    let lhs = WindowAppearanceState(
      opacity: 1, isFullScreen: false, isOpaqueOverride: false, backgroundColorKey: "0,0,0")
    let rhs = WindowAppearanceState(
      opacity: 0, isFullScreen: false, isOpaqueOverride: false, backgroundColorKey: "0,0,0")
    #expect(lhs != rhs)
  }

  @Test func backgroundColorChangeBreaksEquality() {
    let lhs = WindowAppearanceState(
      opacity: 0.7, isFullScreen: false, isOpaqueOverride: false, backgroundColorKey: "26,42,58")
    let rhs = WindowAppearanceState(
      opacity: 0.7, isFullScreen: false, isOpaqueOverride: false, backgroundColorKey: "200,200,200")
    #expect(lhs != rhs)
  }

  @Test func fullScreenChangeBreaksEquality() {
    let lhs = WindowAppearanceState(
      opacity: 0.7, isFullScreen: false, isOpaqueOverride: false, backgroundColorKey: "0,0,0")
    let rhs = WindowAppearanceState(
      opacity: 0.7, isFullScreen: true, isOpaqueOverride: false, backgroundColorKey: "0,0,0")
    #expect(lhs != rhs)
  }

  @Test func opaqueOverrideChangeBreaksEquality() {
    let lhs = WindowAppearanceState(
      opacity: 0.7, isFullScreen: false, isOpaqueOverride: false, backgroundColorKey: "0,0,0")
    let rhs = WindowAppearanceState(
      opacity: 0.7, isFullScreen: false, isOpaqueOverride: true, backgroundColorKey: "0,0,0")
    #expect(lhs != rhs)
  }
}

@MainActor
struct NSColorMatchesTintTests {
  @Test func equalColorsMatchAcrossColorSpaces() {
    let srgb = NSColor(srgbRed: 0.4, green: 0.5, blue: 0.6, alpha: 1)
    let generic = NSColor(red: 0.4, green: 0.5, blue: 0.6, alpha: 1)
    #expect(srgb.matchesTint(generic.usingColorSpace(.sRGB) ?? generic))
    #expect(srgb.matchesTint(srgb))
  }

  @Test func differentColorsDoNotMatch() {
    let lhs = NSColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 1)
    let rhs = NSColor(srgbRed: 0.1, green: 0.2, blue: 0.4, alpha: 1)
    #expect(!lhs.matchesTint(rhs))
  }

  @Test func alphaChangeBreaksMatch() {
    let lhs = NSColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 1)
    let rhs = NSColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 0.5)
    #expect(!lhs.matchesTint(rhs))
  }

  @Test func subThresholdJitterStillMatches() {
    let base = NSColor(srgbRed: 100 / 255, green: 150 / 255, blue: 200 / 255, alpha: 1)
    let jitter = NSColor(srgbRed: 100 / 255 + 0.001, green: 150 / 255, blue: 200 / 255, alpha: 1)
    #expect(base.matchesTint(jitter))
  }

  @Test func adjacentEightBitStepsDoNotMatch() {
    // Adjacent OSC 11 values are exactly 1/255 apart, so they must stay distinct.
    let lhs = NSColor(srgbRed: 100 / 255, green: 0.5, blue: 0.5, alpha: 1)
    let rhs = NSColor(srgbRed: 101 / 255, green: 0.5, blue: 0.5, alpha: 1)
    #expect(!lhs.matchesTint(rhs))
  }

  @Test func nonConvertibleColorDoesNotMatch() {
    // An uncomparable color must read as changed (repaint), never as deduped.
    let pattern = NSColor(patternImage: NSImage(size: NSSize(width: 1, height: 1)))
    let solid = NSColor(srgbRed: 0.4, green: 0.5, blue: 0.6, alpha: 1)
    #expect(!pattern.matchesTint(solid))
    #expect(!solid.matchesTint(pattern))
  }
}
