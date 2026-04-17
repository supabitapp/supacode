import AppKit
import SwiftUI

extension Image {
  /// Creates a tinted SF Symbol image suitable for AppKit menu
  /// rendering. Works around the macOS quirk where `Menu` items
  /// strip SwiftUI color modifiers from SF Symbol icons.
  ///
  /// Automatically resolves the filled variant of the symbol
  /// (appending `.fill` to the name) when one exists, falling
  /// back to the original name. This means callers don't need
  /// to track both outline and filled symbol names separately.
  public static func tintedSymbol(_ name: String, color: NSColor) -> Image {
    let resolvedName = filledSymbolName(for: name)
    let config = NSImage.SymbolConfiguration(paletteColors: [color])
    guard
      let base = NSImage(systemSymbolName: resolvedName, accessibilityDescription: nil),
      let tinted = base.withSymbolConfiguration(config)
    else {
      return Image(systemName: resolvedName)
    }
    tinted.isTemplate = false
    return Image(nsImage: tinted)
  }

  /// Returns the `.fill` variant of a symbol name if it exists,
  /// otherwise returns the original name unchanged.
  private static func filledSymbolName(for name: String) -> String {
    guard !name.hasSuffix(".fill") else { return name }
    let filled = "\(name).fill"
    guard NSImage(systemSymbolName: filled, accessibilityDescription: nil) != nil else {
      return name
    }
    return filled
  }
}
