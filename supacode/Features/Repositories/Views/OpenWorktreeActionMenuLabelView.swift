import AppKit
import SupacodeSettingsShared
import SwiftUI

struct OpenWorktreeActionMenuLabelView: View {
  let action: OpenWorktreeAction

  var body: some View {
    Label {
      Text(action.labelTitle)
    } icon: {
      OpenWorktreeActionIcon(action: action)
    }.labelStyle(.titleAndIcon)
  }
}

extension CGRect {
  /// The unit rect, i.e. an icon whose visible content spans its full canvas.
  fileprivate static let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
}

/// The icon for an open action (resolved app icon or SF Symbol).
struct OpenWorktreeActionIcon: View {
  let action: OpenWorktreeAction

  // Cap for icons whose artwork is unusually small within the canvas.
  private static let maxContentUpscale: CGFloat = 1.4
  private static let alphaSampleSize = 64
  // Low enough to treat the baked shadow as content so it never gets cut.
  private static let alphaThreshold: UInt8 = 8

  // Fitted icons keyed by action id and size; the scan and resize run once per app icon.
  @MainActor private static var fittedIconCache: [String: NSImage] = [:]

  @MainActor
  private func resizedIcon(_ image: NSImage, size: CGSize) -> NSImage {
    let key = "\(action.id):\(size.width)x\(size.height)"
    if let cached = Self.fittedIconCache[key] { return cached }
    guard let content = Self.visibleContentRect(of: image) else {
      // Measurement can fail before the icon rasterizes; skip the cache so the
      // next render retries.
      return Self.fittedIcon(image, content: .unit, size: size)
    }
    let fitted = Self.fittedIcon(image, content: content, size: size)
    Self.fittedIconCache[key] = fitted
    return fitted
  }

  private static func fittedIcon(_ image: NSImage, content: CGRect, size: CGSize) -> NSImage {
    // App icons bake a transparent grid margin that reads smaller than SF Symbols.
    let scale = min(1 / max(content.width, content.height), maxContentUpscale)
    let drawSize = CGSize(width: size.width * scale, height: size.height * scale)
    let drawOrigin = CGPoint(
      x: size.width / 2 - content.midX * drawSize.width,
      y: size.height / 2 - content.midY * drawSize.height
    )
    return NSImage(size: size, flipped: false) { _ in
      image.draw(in: NSRect(origin: drawOrigin, size: drawSize))
      return true
    }
  }

  /// Bounding box of the icon's visible pixels as a unit rect (bottom-left
  /// origin), or `nil` when the icon can't be rasterized yet.
  private static func visibleContentRect(of image: NSImage) -> CGRect? {
    let side = alphaSampleSize
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
    var minColumn = side
    var maxColumn = -1
    var minRow = side
    var maxRow = -1
    for row in 0..<side {
      for column in 0..<side where pixels[(row * side + column) * 4 + 3] > alphaThreshold {
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

  var body: some View {
    if let icon = action.menuIcon {
      switch icon {
      case .app(let image):
        Image(nsImage: resizedIcon(image, size: CGSize(width: 16, height: 16)))
          .renderingMode(.original)
          .accessibilityHidden(true)
      case .symbol(let name):
        Image(systemName: name)
          .foregroundStyle(.primary)
          .accessibilityHidden(true)
      }
    }
  }
}
