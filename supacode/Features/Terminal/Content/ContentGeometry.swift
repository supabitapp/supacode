import AppKit

/// A terminal grid frozen at hibernation, with the exact backing size and font
/// that produced it, so wake can reconstruct the pixel frame the session's zmx
/// snapshot was serialized at.
nonisolated struct FrozenGrid: Equatable, Codable, Sendable {
  /// Real grid reported by the terminal core at freeze time (padding-aware);
  /// used for diagnostics and as a sanity gate, never to re-derive pixels.
  let columns: Int
  let rows: Int
  /// Exact backing pixels the grid was computed from. Wake hands these back
  /// verbatim: re-deriving pixels from columns would drop the padding
  /// remainder and attach one cell short.
  let backingWidth: Double
  let backingHeight: Double
  let scale: Double
  /// Live font size at freeze time; nil means the config default.
  let fontSize: Float32?

  // Persisted shape; a rename must not silently change the wire format.
  private enum CodingKeys: String, CodingKey {
    case columns
    case rows
    case backingWidth
    case backingHeight
    case scale
    case fontSize
  }

  /// Freezes a surface's applied backing size and core-reported grid; nil
  /// while either is still unknown.
  static func from(
    backingSize: CGSize,
    columns: Int,
    rows: Int,
    scale: CGFloat,
    fontSize: Float32?
  ) -> FrozenGrid? {
    guard
      backingSize.width > 0, backingSize.height > 0,
      columns >= 1, rows >= 1, scale > 0
    else { return nil }
    return FrozenGrid(
      columns: columns,
      rows: rows,
      backingWidth: backingSize.width,
      backingHeight: backingSize.height,
      scale: scale,
      fontSize: fontSize
    )
  }
}

/// Deliberate initial geometry for content whose renderer is not yet in a window.
///
/// Off-window views convert to backing at 1x and read their point frame as pixels,
/// so the first PTY grid is honest only when pixels and scale are chosen explicitly.
nonisolated struct ContentGeometry: Equatable, Sendable {
  /// Backing pixels the renderer assumes until real layout lands.
  let pixelSize: CGSize
  /// Display scale for rasterization until the view joins a window.
  let scale: CGFloat

  // Only `candidate`, `restored`, and `fallback` may produce values, so every
  // geometry in circulation satisfies its producer's validation.
  private init(pixelSize: CGSize, scale: CGFloat) {
    self.pixelSize = pixelSize
    self.scale = scale
  }
}

extension ContentGeometry {
  // Below this per-axis point extent a candidate cannot host a usable grid and
  // resolution prefers the next source.
  private static let minimumPointExtent: CGFloat = 64

  /// Last-resort geometry when no window or screen is available.
  static let fallback = ContentGeometry(pixelSize: CGSize(width: 1600, height: 1200), scale: 2)

  /// Pixel geometry of a mounted view; nil when unmounted or degenerate.
  @MainActor
  static func of(mounted view: NSView?) -> ContentGeometry? {
    guard let view, let window = view.window else { return nil }
    // A view inserted but not yet laid out still reports its creation frame,
    // which is already in pixels; clamp to the window so scale is never
    // applied twice.
    let content = window.contentLayoutRect.size
    let size = CGSize(
      width: min(view.bounds.width, content.width),
      height: min(view.bounds.height, content.height)
    )
    return candidate(pointSize: size, scale: window.backingScaleFactor)
  }

  /// Best available geometry from the first mounted, usable anchor, else the
  /// main window's content area, else the main screen, else `fallback`.
  @MainActor
  static func resolve(anchors: [NSView?]) -> ContentGeometry {
    for anchor in anchors {
      if let anchored = of(mounted: anchor) {
        return anchored
      }
    }
    // A closed main window still carries its restored frame, a better estimate
    // than the whole screen, so no visibility gate here.
    if let window = NSApp.mainWindowCandidate(),
      let geometry = candidate(
        pointSize: window.contentLayoutRect.size,
        scale: window.backingScaleFactor
      ) {
      return geometry
    }
    if let screen = NSScreen.main,
      let geometry = candidate(
        pointSize: screen.visibleFrame.size,
        scale: screen.backingScaleFactor
      ) {
      return geometry
    }
    return .fallback
  }

  // Above this per-axis pixel extent a decoded grid is treated as corrupt
  // rather than adopted as a view frame.
  private static let maximumRestoredPixelExtent: Double = 32_768
  // Scale reaches the terminal core unbounded; cap decoded values well above
  // any real display.
  private static let maximumRestoredScale: Double = 8

  /// Geometry reproducing a frozen grid exactly, so a zmx re-attach replays into
  /// the same columns and rows it was serialized at (#780).
  static func restored(_ grid: FrozenGrid) -> ContentGeometry? {
    // Finiteness and cap guard decoded values: an absurd size would become the
    // view frame and trap in integer conversion.
    guard
      grid.columns > 0, grid.rows > 0,
      grid.backingWidth.isFinite, grid.backingHeight.isFinite, grid.scale.isFinite,
      grid.backingWidth > 0, grid.backingHeight > 0, grid.scale > 0,
      grid.backingWidth <= maximumRestoredPixelExtent,
      grid.backingHeight <= maximumRestoredPixelExtent,
      grid.scale <= maximumRestoredScale
    else { return nil }
    return ContentGeometry(
      pixelSize: CGSize(width: grid.backingWidth, height: grid.backingHeight),
      scale: grid.scale
    )
  }

  /// Converts a point size at a scale into pixel geometry; nil when too small to
  /// host a usable grid, so resolution can prefer the next candidate.
  static func candidate(pointSize: CGSize, scale: CGFloat) -> ContentGeometry? {
    guard
      pointSize.width >= minimumPointExtent,
      pointSize.height >= minimumPointExtent,
      scale > 0
    else { return nil }
    return ContentGeometry(
      pixelSize: CGSize(width: pointSize.width * scale, height: pointSize.height * scale),
      scale: scale
    )
  }
}
