import AppKit
import SwiftUI

/// User-customizable tint for sidebar headers, script icons, and tab dots.
/// Predefined cases serialize as `"red"` / `"teal"` / ...; `.custom(hex)`
/// carries `#RRGGBB[AA]`. Malformed values decode to `nil` so the UI can
/// fall back to the kind / default tint.
public nonisolated enum RepositoryColor: Hashable, Sendable, Codable {
  case red
  case orange
  case yellow
  case green
  case teal
  case blue
  case purple
  case custom(String)

  /// Wire format: `"red"` / `"orange"` / ... / `"#A1B2C3"`.
  public var rawValue: String {
    switch self {
    case .red: "red"
    case .orange: "orange"
    case .yellow: "yellow"
    case .green: "green"
    case .teal: "teal"
    case .blue: "blue"
    case .purple: "purple"
    case .custom(let hex): hex
    }
  }

  /// Predefined name → case; `#`-prefixed valid hex → `.custom(hex)`; else `nil`.
  public static func parse(_ rawValue: String) -> RepositoryColor? {
    switch rawValue.lowercased() {
    case "red": return .red
    case "orange": return .orange
    case "yellow": return .yellow
    case "green": return .green
    case "teal": return .teal
    case "blue": return .blue
    case "purple": return .purple
    default:
      guard rawValue.hasPrefix("#"), Self.isValidHex(rawValue) else {
        return nil
      }
      return .custom(rawValue.uppercased())
    }
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let raw = try container.decode(String.self)
    guard let parsed = Self.parse(raw) else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Unrecognized color value: \(raw)"
      )
    }
    self = parsed
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  public static let predefined: [RepositoryColor] = [.red, .orange, .yellow, .green, .teal, .blue, .purple]

  /// SwiftUI tint; predefined cases track the system palette, `.custom` parses the hex.
  public var color: Color {
    switch self {
    case .red: .red
    case .orange: .orange
    case .yellow: .yellow
    case .green: .green
    case .teal: .teal
    case .blue: .blue
    case .purple: .purple
    case .custom(let hex): Color(nsColor: Self.nsColor(fromHex: hex) ?? .systemGray)
    }
  }

  /// AppKit counterpart of `color`, for NSImage / NSMenu tinting.
  public var nsColor: NSColor {
    switch self {
    case .red: .systemRed
    case .orange: .systemOrange
    case .yellow: .systemYellow
    case .green: .systemGreen
    case .teal: .systemTeal
    case .blue: .systemBlue
    case .purple: .systemPurple
    case .custom(let hex): Self.nsColor(fromHex: hex) ?? .systemGray
    }
  }

  /// Tooltip label used by `ColorSwatchRow`'s predefined swatches.
  public var displayName: String {
    switch self {
    case .red: "Red"
    case .orange: "Orange"
    case .yellow: "Yellow"
    case .green: "Green"
    case .teal: "Teal"
    case .blue: "Blue"
    case .purple: "Purple"
    case .custom(let hex): hex
    }
  }

  /// `true` for `.custom`; lets callers avoid spelling out the case path.
  public var isCustom: Bool {
    if case .custom = self { return true }
    return false
  }

  /// Build `.custom(hex)` from a SwiftUI `Color`; nil if NSColor can't resolve to sRGB.
  public static func custom(from color: Color) -> RepositoryColor? {
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
