import AppKit
import SwiftUI

/// Tint applied to a repository's sidebar header. Stored verbatim
/// in `sidebar.json` under each section's `color` key. The
/// `predefined` cases match the canonical six-color palette
/// (red / orange / yellow / green / blue / purple); `custom` carries
/// an arbitrary `#RRGGBB` (or `#RRGGBBAA`) string supplied through
/// the SwiftUI color picker. Any unknown `custom` payload (malformed
/// hex, etc.) decodes to `nil` at the call site via the
/// `RepositoryColor?` field on `SidebarState.Section`.
nonisolated enum RepositoryColor: Hashable, Sendable, Codable {
  case red
  case orange
  case yellow
  case green
  case blue
  case purple
  case custom(String)

  /// Stable identifiers for the predefined cases. `custom(...)` is
  /// represented by its hex payload, so the JSON wire format stays
  /// `"red"` / `"orange"` / ... / `"#A1B2C3"`.
  var rawValue: String {
    switch self {
    case .red: "red"
    case .orange: "orange"
    case .yellow: "yellow"
    case .green: "green"
    case .blue: "blue"
    case .purple: "purple"
    case .custom(let hex): hex
    }
  }

  /// Decode from the stored string form. Predefined names map to
  /// their cases; anything starting with `#` and containing a valid
  /// hex payload becomes `.custom(hex)`. Everything else returns
  /// `nil`, which the optional `color` field on `SidebarState.Section`
  /// surfaces to the UI as "no tint".
  static func parse(_ rawValue: String) -> RepositoryColor? {
    switch rawValue.lowercased() {
    case "red": return .red
    case "orange": return .orange
    case "yellow": return .yellow
    case "green": return .green
    case "blue": return .blue
    case "purple": return .purple
    default:
      guard rawValue.hasPrefix("#"), Self.isValidHex(rawValue) else {
        return nil
      }
      return .custom(rawValue.uppercased())
    }
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let raw = try container.decode(String.self)
    guard let parsed = Self.parse(raw) else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Unrecognized repository color value: \(raw)"
      )
    }
    self = parsed
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  static let predefined: [RepositoryColor] = [.red, .orange, .yellow, .green, .blue, .purple]

  /// SwiftUI tint for the resolved color. Predefined cases use the
  /// system palette; `.custom(hex)` parses the stored hex string.
  var color: Color {
    switch self {
    case .red: .red
    case .orange: .orange
    case .yellow: .yellow
    case .green: .green
    case .blue: .blue
    case .purple: .purple
    case .custom(let hex): Color(nsColor: Self.nsColor(fromHex: hex) ?? .systemGray)
    }
  }

  /// Display label for the color — used as the predefined swatch
  /// tooltip in `RepositoryCustomizationView`. Predefined cases use
  /// their capitalized name; the `.custom` arm echoes the hex
  /// payload and is currently unreachable from the UI (the custom
  /// swatch hard-codes "Custom"), kept only to keep the switch
  /// exhaustive.
  var displayName: String {
    switch self {
    case .red: "Red"
    case .orange: "Orange"
    case .yellow: "Yellow"
    case .green: "Green"
    case .blue: "Blue"
    case .purple: "Purple"
    case .custom(let hex): hex
    }
  }

  /// `true` when this is a `custom` case. Drives picker selection
  /// state without forcing call sites to spell out the case path.
  var isCustom: Bool {
    if case .custom = self { return true }
    return false
  }

  /// Build a custom color from a SwiftUI `Color`. Falls back to
  /// `nil` when the bridged `NSColor` can't resolve to RGB (e.g. a
  /// catalog color the picker can't normalize).
  static func custom(from color: Color) -> RepositoryColor? {
    let nsColor = NSColor(color)
    guard let rgb = nsColor.usingColorSpace(.sRGB) else { return nil }
    return .custom(hex(from: rgb))
  }

  private static func hex(from nsColor: NSColor) -> String {
    let rgb = nsColor.usingColorSpace(.sRGB) ?? nsColor
    let red = Int(round(rgb.redComponent * 255))
    let green = Int(round(rgb.greenComponent * 255))
    let blue = Int(round(rgb.blueComponent * 255))
    return String(format: "#%02X%02X%02X", red, green, blue)
  }

  private static func nsColor(fromHex hex: String) -> NSColor? {
    var raw = hex
    if raw.hasPrefix("#") { raw.removeFirst() }
    guard raw.count == 6 || raw.count == 8 else { return nil }
    var value: UInt64 = 0
    guard Scanner(string: raw).scanHexInt64(&value) else { return nil }
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat
    if raw.count == 8 {
      red = CGFloat((value & 0xFF00_0000) >> 24) / 255
      green = CGFloat((value & 0x00FF_0000) >> 16) / 255
      blue = CGFloat((value & 0x0000_FF00) >> 8) / 255
      alpha = CGFloat(value & 0x0000_00FF) / 255
    } else {
      red = CGFloat((value & 0xFF0000) >> 16) / 255
      green = CGFloat((value & 0x00FF00) >> 8) / 255
      blue = CGFloat(value & 0x0000FF) / 255
      alpha = 1
    }
    return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
  }

  private static func isValidHex(_ string: String) -> Bool {
    nsColor(fromHex: string) != nil
  }
}
