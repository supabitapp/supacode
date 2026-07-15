import AppKit
import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

private nonisolated let iconLogger = SupaLogger("OpenActionIcon")

extension CGRect {
  /// The unit rect, i.e. an icon whose visible content spans its full canvas.
  nonisolated static let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
}

/// The pure fit math behind #650: app icons bake a transparent grid margin that
/// reads smaller than an SF Symbol, so their visible content is measured and
/// scaled up to the symbol footprint. Kept free of IconServices so it is testable.
nonisolated enum OpenActionIconGeometry {
  /// Cap for icons whose artwork is unusually small within the canvas.
  static let maxContentUpscale: CGFloat = 1.4
  static let alphaSampleSize = 64
  /// Low enough to treat the baked shadow as content so it never gets cut.
  static let alphaThreshold: UInt8 = 8

  /// Where to draw the full icon so that its visible `content` (a unit rect)
  /// fills and centers on a `size` canvas.
  static func drawRect(content: CGRect, size: CGSize) -> CGRect {
    let scale = min(1 / max(content.width, content.height), maxContentUpscale)
    let drawSize = CGSize(width: size.width * scale, height: size.height * scale)
    let drawOrigin = CGPoint(
      x: size.width / 2 - content.midX * drawSize.width,
      y: size.height / 2 - content.midY * drawSize.height
    )
    return CGRect(origin: drawOrigin, size: drawSize)
  }

  /// Bounding box of the visible pixels in a top-down premultiplied-RGBA buffer
  /// of `side` x `side` pixels, as a unit rect with a bottom-left origin.
  static func visibleContentRect(rgba: [UInt8], side: Int) -> CGRect {
    var minColumn = side
    var maxColumn = -1
    var minRow = side
    var maxRow = -1
    for row in 0..<side {
      for column in 0..<side where rgba[(row * side + column) * 4 + 3] > alphaThreshold {
        minColumn = min(minColumn, column)
        maxColumn = max(maxColumn, column)
        minRow = min(minRow, row)
        maxRow = max(maxRow, row)
      }
    }
    // A fully transparent icon is a legitimate measurement, not a failure.
    guard maxColumn >= minColumn, maxRow >= minRow else { return .unit }
    let sampleCount = CGFloat(side)
    // Buffer rows are top-down; flip into bottom-left image coordinates.
    return CGRect(
      x: CGFloat(minColumn) / sampleCount,
      y: (sampleCount - CGFloat(maxRow) - 1) / sampleCount,
      width: CGFloat(maxColumn - minColumn + 1) / sampleCount,
      height: CGFloat(maxRow - minRow + 1) / sampleCount
    )
  }
}

/// Rasterizes and bakes app icons. Every step here is a synchronous
/// IconServices round-trip, so it only ever runs from `OpenActionIconStore.warm`.
nonisolated enum OpenActionIconBaker {
  /// Point size of a menu icon, matching the SF Symbol it sits beside.
  static let iconSize = CGSize(width: 16, height: 16)
  /// Baked once at 2x. Keying on the window's backing scale would reintroduce a
  /// main-thread miss the moment the window moves to another display.
  static let bakeScale: CGFloat = 2

  /// The fitted, fully rasterized icon for `image`, or `nil` when it can't be
  /// rasterized (a cacheable negative, never a retry).
  static func bake(_ image: NSImage) -> NSImage? {
    guard let content = measure(image) else { return nil }
    return render(image, content: content)
  }

  /// The visible-content unit rect of `image`, or `nil` when it can't rasterize.
  private static func measure(_ image: NSImage) -> CGRect? {
    let side = OpenActionIconGeometry.alphaSampleSize
    var proposed = NSRect(x: 0, y: 0, width: side, height: side)
    guard let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
      return nil
    }
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer in
      guard
        let base = buffer.baseAddress,
        let context = CGContext(
          data: base,
          width: side,
          height: side,
          bitsPerComponent: 8,
          bytesPerRow: side * 4,
          space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
      else { return false }
      context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
      return true
    }
    guard drawn else { return nil }
    return OpenActionIconGeometry.visibleContentRect(rgba: pixels, side: side)
  }

  /// Draws the fitted icon into a bitmap rep. `NSImage(size:flipped:)` would
  /// keep a lazy draw handler that fires mid-menu-tracking on the main thread,
  /// so the pixels are baked here instead.
  private static func render(_ image: NSImage, content: CGRect) -> NSImage? {
    let size = iconSize
    let pixelsWide = Int((size.width * bakeScale).rounded())
    let pixelsHigh = Int((size.height * bakeScale).rounded())
    guard
      let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelsWide,
        pixelsHigh: pixelsHigh,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      )
    else { return nil }
    // Before the context: `NSGraphicsContext(bitmapImageRep:)` freezes its CTM
    // from the rep's size, so a rep left at its pixel size would map the 16 pt
    // draw onto 16 of the 32 px and bake the icon into a corner. It also has to
    // be set at all, or the menu lays the icon out at 32 pt.
    rep.size = size
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    let previous = NSGraphicsContext.current
    NSGraphicsContext.current = context
    image.draw(in: OpenActionIconGeometry.drawRect(content: content, size: size))
    context.flushGraphics()
    NSGraphicsContext.current = previous
    let baked = NSImage(size: size)
    baked.addRepresentation(rep)
    return baked
  }
}

/// Fitted app icons for the Open menus. `NSImage` is not sensibly Equatable, so
/// it must never enter TCA state; this is a plain observable store instead.
@MainActor
@Observable
final class OpenActionIconStore {
  nonisolated enum IconState {
    case ready(NSImage)
    case unavailable
  }

  /// Crosses the actor boundary out of the baking task. The images are built
  /// there and never mutated afterwards.
  private nonisolated struct BakedIcons: @unchecked Sendable {
    let entries: [OpenWorktreeAction.ID: IconState]
    /// Split from the bake failures below: an action the availability sweep just
    /// called installed but LaunchServices won't locate is a different fault.
    let unresolvedIDs: [OpenWorktreeAction.ID]
    let failedBakeIDs: [OpenWorktreeAction.ID]
  }

  private var icons: [OpenWorktreeAction.ID: IconState] = [:]
  /// Cancelling the `.task(id:)` that awaits a warm doesn't cancel its detached
  /// baking task, so overlapping warms would bake the same icons twice.
  @ObservationIgnored private var inFlight: Set<OpenWorktreeAction.ID> = []
  @ObservationIgnored @Dependency(\.openActionAvailability) private var availability

  /// A pure dictionary read: a miss renders nothing and never kicks off work.
  func icon(for action: OpenWorktreeAction) -> NSImage? {
    guard case .ready(let image) = icons[action.id] else { return nil }
    return image
  }

  /// Resolves, rasterizes, and bakes every icon not already cached. Failures are
  /// cached as `.unavailable` so a never-rasterizing icon is probed once, not per render.
  func warm(_ actions: [OpenWorktreeAction]) async {
    // A negative lasts only until the next warm. IconServices is busiest at launch,
    // and a hiccup there would otherwise cost that action its icon for the session.
    // Warms are rare (the installed set changed, or the host view came back), so this
    // retries roughly when a retry could plausibly succeed, and never on a render.
    let retried = icons.filter { if case .unavailable = $0.value { false } else { true } }
    if retried.count != icons.count {
      icons = retried
    }

    let pending = actions.filter {
      $0.menuSymbolName == nil && icons[$0.id] == nil && !inFlight.contains($0.id)
    }
    guard !pending.isEmpty else { return }
    let pendingIDs = Set(pending.map(\.id))
    inFlight.formUnion(pendingIDs)
    defer { inFlight.subtract(pendingIDs) }
    let requests = pending.map { (id: $0.id, bundleIdentifier: $0.bundleIdentifier) }
    let availability = availability
    // AppKit permits the icon fetch and the draw off-main as long as the image isn't
    // shared across threads: each is fetched, drawn, and handed over inside this task.
    let baked = await Task.detached(priority: .utility) {
      var entries: [OpenWorktreeAction.ID: IconState] = [:]
      var unresolvedIDs: [OpenWorktreeAction.ID] = []
      var failedBakeIDs: [OpenWorktreeAction.ID] = []
      for request in requests {
        guard let appURL = availability.applicationURL(request.bundleIdentifier) else {
          entries[request.id] = .unavailable
          unresolvedIDs.append(request.id)
          continue
        }
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        guard let baked = OpenActionIconBaker.bake(icon) else {
          entries[request.id] = .unavailable
          failedBakeIDs.append(request.id)
          continue
        }
        entries[request.id] = .ready(baked)
      }
      return BakedIcons(
        entries: entries,
        unresolvedIDs: unresolvedIDs.sorted(),
        failedBakeIDs: failedBakeIDs.sorted()
      )
    }.value
    // One batched write so a warm pass invalidates every icon view exactly once.
    icons.merge(baked.entries) { _, new in new }

    if !baked.unresolvedIDs.isEmpty {
      iconLogger.warning(
        "Installed but unlocatable, so no icon: \(baked.unresolvedIDs.joined(separator: ", "))."
      )
    }
    if !baked.failedBakeIDs.isEmpty {
      iconLogger.error("Unable to bake the menu icon for \(baked.failedBakeIDs.joined(separator: ", ")).")
    }
  }
}
