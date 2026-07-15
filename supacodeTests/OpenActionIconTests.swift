import AppKit
import ConcurrencyExtras
import CoreGraphics
import Dependencies
import DependenciesTestSupport
import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

/// Guards the #650 icon fit (visible-content bounding box, scaled up to the SF
/// Symbol footprint and recentered) against synthetic bitmaps, so the sizing has
/// a regression test that never touches IconServices.
struct OpenActionIconGeometryTests {
  private static let side = OpenActionIconGeometry.alphaSampleSize
  private static let iconSize = CGSize(width: 16, height: 16)

  /// A top-down premultiplied-RGBA buffer with `alpha` in the given pixel box.
  private static func buffer(
    columns: Range<Int>,
    rows: Range<Int>,
    alpha: UInt8 = 255
  ) -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    for row in rows {
      for column in columns {
        pixels[(row * side + column) * 4 + 3] = alpha
      }
    }
    return pixels
  }

  private static func expectClose(_ value: CGFloat, _ expected: CGFloat, _ label: String) {
    #expect(abs(value - expected) < 0.0001, "\(label): \(value) != \(expected)")
  }

  @Test func fullyTransparentIconMeasuresAsTheUnitRect() {
    let rect = OpenActionIconGeometry.visibleContentRect(
      rgba: Self.buffer(columns: 0..<0, rows: 0..<0),
      side: Self.side
    )
    #expect(rect == .unit)
  }

  @Test func alphaBelowTheThresholdIsNotContent() {
    let rect = OpenActionIconGeometry.visibleContentRect(
      rgba: Self.buffer(columns: 0..<Self.side, rows: 0..<Self.side, alpha: 8),
      side: Self.side
    )
    #expect(rect == .unit)
  }

  @Test func alphaJustAboveTheThresholdIsContent() {
    // The other side of the boundary: a baked shadow at alpha 9 is content, so it
    // measures as the box it occupies rather than falling back to the unit rect.
    let rect = OpenActionIconGeometry.visibleContentRect(
      rgba: Self.buffer(columns: 16..<48, rows: 16..<48, alpha: 9),
      side: Self.side
    )
    Self.expectClose(rect.origin.x, 0.25, "x")
    Self.expectClose(rect.width, 0.5, "width")
  }

  @Test func centeredContentMeasuresAsACenteredUnitRect() {
    let rect = OpenActionIconGeometry.visibleContentRect(
      rgba: Self.buffer(columns: 16..<48, rows: 16..<48),
      side: Self.side
    )
    Self.expectClose(rect.origin.x, 0.25, "x")
    Self.expectClose(rect.origin.y, 0.25, "y")
    Self.expectClose(rect.width, 0.5, "width")
    Self.expectClose(rect.height, 0.5, "height")
  }

  @Test func measurementFlipsTopDownRowsIntoBottomLeftCoordinates() {
    // Content in the buffer's top-left quadrant sits in the image's top-left,
    // i.e. a bottom-left origin of y = 0.5.
    let rect = OpenActionIconGeometry.visibleContentRect(
      rgba: Self.buffer(columns: 0..<32, rows: 0..<32),
      side: Self.side
    )
    Self.expectClose(rect.origin.x, 0, "x")
    Self.expectClose(rect.origin.y, 0.5, "y")
    Self.expectClose(rect.width, 0.5, "width")
    Self.expectClose(rect.height, 0.5, "height")
  }

  @Test func fullBleedIconIsDrawnAtItsNaturalSize() {
    let rect = OpenActionIconGeometry.drawRect(content: .unit, size: Self.iconSize)
    #expect(rect == CGRect(x: 0, y: 0, width: 16, height: 16))
  }

  @Test func insetIconIsUpscaledAndRecentered() {
    let content = OpenActionIconGeometry.visibleContentRect(
      rgba: Self.buffer(columns: 16..<48, rows: 16..<48),
      side: Self.side
    )
    let rect = OpenActionIconGeometry.drawRect(content: content, size: Self.iconSize)
    // Halved content wants a 2x upscale but the cap holds it at 1.4.
    Self.expectClose(rect.width, 16 * OpenActionIconGeometry.maxContentUpscale, "width")
    Self.expectClose(rect.height, 16 * OpenActionIconGeometry.maxContentUpscale, "height")
    Self.expectClose(rect.origin.x, -3.2, "x")
    Self.expectClose(rect.origin.y, -3.2, "y")
  }

  @Test func upscaleIsCappedForTinyArtwork() {
    let content = OpenActionIconGeometry.visibleContentRect(
      rgba: Self.buffer(columns: 30..<34, rows: 30..<34),
      side: Self.side
    )
    let rect = OpenActionIconGeometry.drawRect(content: content, size: Self.iconSize)
    Self.expectClose(rect.width, 16 * OpenActionIconGeometry.maxContentUpscale, "width")
  }

  @Test func offCenterContentIsRecenteredOnTheCanvas() {
    let content = OpenActionIconGeometry.visibleContentRect(
      rgba: Self.buffer(columns: 0..<32, rows: 0..<32),
      side: Self.side
    )
    let rect = OpenActionIconGeometry.drawRect(content: content, size: Self.iconSize)
    // The content's midpoint lands on the canvas center in both axes.
    Self.expectClose(rect.origin.x + content.midX * rect.width, 8, "content midX")
    Self.expectClose(rect.origin.y + content.midY * rect.height, 8, "content midY")
  }
}

/// Covers the bake itself against a synthetic bitmap, so the menu-icon sizing has
/// a regression test that never touches IconServices.
@MainActor
struct OpenActionIconBakerTests {
  /// An opaque square icon whose artwork is inset by `inset` pixels per side.
  private static func makeIcon(pixels: Int, inset: Int = 0) throws -> NSImage {
    let rep = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      )
    )
    let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
    let previous = NSGraphicsContext.current
    NSGraphicsContext.current = context
    NSColor.red.setFill()
    NSRect(
      x: inset,
      y: inset,
      width: pixels - inset * 2,
      height: pixels - inset * 2
    ).fill()
    context.flushGraphics()
    NSGraphicsContext.current = previous

    let image = NSImage(size: NSSize(width: pixels, height: pixels))
    image.addRepresentation(rep)
    return image
  }

  /// Width in pixels of the opaque box in a baked rep.
  private static func opaqueWidth(of rep: NSBitmapImageRep) -> Int {
    var minColumn = rep.pixelsWide
    var maxColumn = -1
    for row in 0..<rep.pixelsHigh {
      for column in 0..<rep.pixelsWide
      where (rep.colorAt(x: column, y: row)?.alphaComponent ?? 0) > 0.5 {
        minColumn = min(minColumn, column)
        maxColumn = max(maxColumn, column)
      }
    }
    guard maxColumn >= minColumn else { return 0 }
    return maxColumn - minColumn + 1
  }

  @Test func bakedIconIsSixteenPointsAtTheBakeScale() throws {
    let baked = try #require(OpenActionIconBaker.bake(Self.makeIcon(pixels: 128)))

    #expect(baked.size == OpenActionIconBaker.iconSize)
    let rep = try #require(baked.representations.first as? NSBitmapImageRep)
    // Rasterized at 2x, but the rep must report the point size or AppKit lays the
    // icon out at its pixel size: 32 pt in the menu, next to a 16 pt SF Symbol.
    #expect(rep.size == OpenActionIconBaker.iconSize)
    #expect(rep.pixelsWide == 32)
    #expect(rep.pixelsHigh == 32)
    // Full-bleed artwork is drawn at its natural size: it fills the canvas.
    #expect(Self.opaqueWidth(of: rep) == 32)
  }

  @Test func insetArtworkIsUpscaledTowardsTheSymbolFootprint() throws {
    // Artwork spanning half the canvas wants a 2x upscale and gets the capped
    // 1.4x, so it bakes wider than the 16 px a naive natural-size draw yields.
    let baked = try #require(OpenActionIconBaker.bake(Self.makeIcon(pixels: 128, inset: 32)))
    let rep = try #require(baked.representations.first as? NSBitmapImageRep)

    // Half-canvas artwork wants 2x, takes the 1.4x cap, so it bakes to
    // 32 * 0.5 * 1.4 = 22.4 px. An upper bound alone cannot fail here: the rep is
    // only 32 px wide, so dropping the cap entirely would still satisfy it.
    #expect((21...23).contains(Self.opaqueWidth(of: rep)))
  }
}

@MainActor
struct OpenActionIconStoreTests {
  @Test(.dependencies) func unresolvableIconIsCachedAsUnavailableAndRetriedOnTheNextWarm() async {
    let probes = LockIsolated([String]())
    let store = withDependencies {
      $0.openActionAvailability.applicationURL = { bundleIdentifier in
        probes.withValue { $0.append(bundleIdentifier) }
        return nil
      }
    } operation: {
      OpenActionIconStore()
    }

    await store.warm([.vscode, .editor])
    #expect(probes.value == [OpenWorktreeAction.vscode.bundleIdentifier])
    #expect(store.icon(for: .vscode) == nil)

    // The negative is cached against renders, which is what must never probe.
    #expect(store.icon(for: .vscode) == nil)
    #expect(probes.value.count == 1)

    // It does not outlive the next warm: IconServices can fail transiently at launch,
    // and warms are rare enough that retrying one there is the cheap side of the trade.
    await store.warm([.vscode, .editor])
    #expect(probes.value.count == 2)
  }

  @Test(.dependencies) func symbolActionsAreNeverProbed() async {
    let probes = LockIsolated(0)
    let store = withDependencies {
      $0.openActionAvailability.applicationURL = { _ in
        probes.withValue { $0 += 1 }
        return nil
      }
    } operation: {
      OpenActionIconStore()
    }

    await store.warm([.editor])
    #expect(probes.value == 0)
    #expect(store.icon(for: .editor) == nil)
  }

  @Test(.dependencies) func iconReadIsPureAndReturnsNilBeforeWarming() {
    let probes = LockIsolated(0)
    let store = withDependencies {
      $0.openActionAvailability.applicationURL = { _ in
        probes.withValue { $0 += 1 }
        return nil
      }
    } operation: {
      OpenActionIconStore()
    }

    #expect(store.icon(for: .vscode) == nil)
    #expect(store.icon(for: .vscode) == nil)
    #expect(probes.value == 0)
  }
}
