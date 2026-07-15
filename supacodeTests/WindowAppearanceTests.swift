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

@MainActor
struct WindowTintMaskTests {
  private let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)

  @Test func noSurfacesFillsWholeBackdrop() {
    #expect(WindowChromeApplier.maskHoleRects(holeRects: [], bounds: bounds) == [bounds])
  }

  @Test func surfaceIsPunchedOut() {
    let surface = CGRect(x: 10, y: 10, width: 40, height: 40)
    #expect(
      WindowChromeApplier.maskHoleRects(holeRects: [surface], bounds: bounds)
        == [bounds, surface])
  }

  @Test func multipleSurfacesAreAllPunchedInOrder() {
    let first = CGRect(x: 5, y: 5, width: 20, height: 20)
    let second = CGRect(x: 60, y: 60, width: 30, height: 30)
    #expect(
      WindowChromeApplier.maskHoleRects(holeRects: [first, second], bounds: bounds)
        == [bounds, first, second])
  }

  // A dropped middle hole must not disturb the order/position of later holes.
  @Test func droppedMiddleHoleLeavesOrderIntact() {
    let first = CGRect(x: 5, y: 5, width: 20, height: 20)
    let dropped = CGRect(x: 200, y: 200, width: 10, height: 10)
    let second = CGRect(x: 60, y: 60, width: 30, height: 30)
    #expect(
      WindowChromeApplier.maskHoleRects(holeRects: [first, dropped, second], bounds: bounds)
        == [bounds, first, second])
  }

  // A surface poking past an edge is punched as its intersection with the
  // backdrop, not the raw rect.
  @Test func overhangingSurfaceIsClippedToBounds() {
    let overhang = CGRect(x: 80, y: 80, width: 40, height: 40)
    #expect(
      WindowChromeApplier.maskHoleRects(holeRects: [overhang], bounds: bounds)
        == [bounds, CGRect(x: 80, y: 80, width: 20, height: 20)])
  }

  @Test func zeroAreaAndNonIntersectingRectsAreDropped() {
    let zeroArea = CGRect(x: 5, y: 5, width: 0, height: 30)
    let outside = CGRect(x: 200, y: 200, width: 10, height: 10)
    #expect(
      WindowChromeApplier.maskHoleRects(holeRects: [zeroArea, outside], bounds: bounds)
        == [bounds])
  }

  // A rect spanning the whole backdrop would even-odd-cancel the entire tint
  // (fully transparent window); it must be dropped.
  @Test func fullBackdropSpanningRectIsDropped() {
    let spanning = CGRect(x: -50, y: -50, width: 300, height: 300)
    #expect(
      WindowChromeApplier.maskHoleRects(holeRects: [spanning], bounds: bounds) == [bounds])
  }
}
