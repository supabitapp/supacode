import AppKit
import Testing

@testable import supacode

struct ContentGeometryTests {
  @Test func candidateScalesPointsIntoPixels() {
    let geometry = ContentGeometry.candidate(
      pointSize: CGSize(width: 800, height: 600),
      scale: 2
    )
    #expect(geometry?.pixelSize == CGSize(width: 1600, height: 1200))
    #expect(geometry?.scale == 2)
  }

  @Test func candidateKeepsOneXPixelsVerbatim() {
    let geometry = ContentGeometry.candidate(
      pointSize: CGSize(width: 1024, height: 768),
      scale: 1
    )
    #expect(geometry?.pixelSize == CGSize(width: 1024, height: 768))
    #expect(geometry?.scale == 1)
  }

  @Test func candidateRejectsSizesTooSmallForAGrid() {
    #expect(ContentGeometry.candidate(pointSize: CGSize(width: 63, height: 600), scale: 2) == nil)
    #expect(ContentGeometry.candidate(pointSize: CGSize(width: 800, height: 63), scale: 2) == nil)
    #expect(ContentGeometry.candidate(pointSize: .zero, scale: 2) == nil)
  }

  @Test func candidateRejectsNonPositiveScale() {
    #expect(ContentGeometry.candidate(pointSize: CGSize(width: 800, height: 600), scale: 0) == nil)
  }

  @Test func frozenGridDerivesFromAppliedSizeAndCellMetrics() {
    let grid = FrozenGrid.from(
      backingSize: CGSize(width: 1608, height: 1206),
      cellSize: CGSize(width: 17, height: 37),
      scale: 2,
      fontSize: 14
    )
    #expect(grid?.columns == 94)
    #expect(grid?.rows == 32)
    #expect(grid?.cellWidth == 17)
    #expect(grid?.cellHeight == 37)
    #expect(grid?.scale == 2)
    #expect(grid?.fontSize == 14)
  }

  @Test func frozenGridIsNilWhileMetricsAreUnknown() {
    #expect(
      FrozenGrid.from(
        backingSize: .zero,
        cellSize: CGSize(width: 17, height: 37),
        scale: 2,
        fontSize: nil
      ) == nil
    )
    #expect(
      FrozenGrid.from(
        backingSize: CGSize(width: 1608, height: 1206),
        cellSize: .zero,
        scale: 2,
        fontSize: nil
      ) == nil
    )
  }

  @Test func restoredGeometryReproducesTheFrozenGridExactly() throws {
    let grid = try #require(
      FrozenGrid.from(
        backingSize: CGSize(width: 1700, height: 1230),
        cellSize: CGSize(width: 17, height: 37),
        scale: 2,
        fontSize: nil
      )
    )
    let geometry = try #require(ContentGeometry.restored(grid))
    // The reconstructed pixel frame floors back to the same columns and rows.
    #expect(Int(geometry.pixelSize.width / 17) == grid.columns)
    #expect(Int(geometry.pixelSize.height / 37) == grid.rows)
    #expect(geometry.scale == 2)
  }

  @Test @MainActor func unmountedAnchorYieldsNoMountedGeometry() {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    #expect(ContentGeometry.of(mounted: view) == nil)
    #expect(ContentGeometry.of(mounted: nil) == nil)
  }

  @Test @MainActor func mountedGeometryClampsToTheWindowContentArea() {
    // A not-yet-laid-out view reports its creation frame, which is already in
    // pixels; the clamp keeps scale from being applied twice.
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
      styleMask: .borderless,
      backing: .buffered,
      defer: true
    )
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 3200, height: 2400))
    window.contentView?.addSubview(view)
    let geometry = ContentGeometry.of(mounted: view)
    let scale = window.backingScaleFactor
    #expect(geometry?.pixelSize == CGSize(width: 700 * scale, height: 500 * scale))
    window.orderOut(nil)
  }

  @Test @MainActor func resolveSkipsADegenerateMountedAnchorForTheNextOne() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
      styleMask: .borderless,
      backing: .buffered,
      defer: true
    )
    let sliver = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 700))
    let pane = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 700))
    window.contentView?.addSubview(sliver)
    window.contentView?.addSubview(pane)
    let geometry = ContentGeometry.resolve(anchors: [sliver, pane])
    let scale = window.backingScaleFactor
    #expect(geometry.pixelSize == CGSize(width: 600 * scale, height: 700 * scale))
    window.orderOut(nil)
  }
}
