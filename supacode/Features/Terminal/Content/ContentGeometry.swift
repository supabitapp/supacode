import AppKit

/// Deliberate initial geometry for content whose renderer is not yet in a window.
///
/// Off-window views convert to backing at 1x and read their point frame as pixels,
/// so the first PTY grid is honest only when pixels and scale are chosen explicitly.
nonisolated struct ContentGeometry: Equatable, Sendable {
  /// Backing pixels the renderer assumes until real layout lands.
  let pixelSize: CGSize
  /// Display scale for rasterization until the view joins a window.
  let scale: CGFloat

  // Only `candidate` and `fallback` may produce values, so every geometry in
  // circulation satisfies the minimum-grid and positive-scale invariants.
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
