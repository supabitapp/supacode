import AppKit

/// Fixed, named text-size presets for the notes editor. Each maps to a Dynamic
/// Type text style so sizes still scale with the system text setting (per the
/// project's "avoid hardcoded font sizes" guideline) while giving the user a
/// small, fixed set of choices in the format bar.
enum NoteTextStyle: String, Codable, Equatable, Sendable, CaseIterable, Identifiable {
  case small
  case body
  case large
  case title

  var id: String { rawValue }

  /// Short user-facing label for the format-bar picker.
  var label: String {
    switch self {
    case .small: "Pequeno"
    case .body: "Normal"
    case .large: "Grande"
    case .title: "Título"
    }
  }

  /// AppKit text style this preset resolves to.
  var nsTextStyle: NSFont.TextStyle {
    switch self {
    case .small: .subheadline
    case .body: .body
    case .large: .title3
    case .title: .title1
    }
  }

  /// Base (trait-free) font for this preset, scaled by Dynamic Type.
  var baseFont: NSFont {
    NSFont.preferredFont(forTextStyle: nsTextStyle)
  }

  /// Best-effort classification of a font back into a preset, so the format bar
  /// can highlight the active size. Falls back to `.body`.
  static func from(pointSize: CGFloat) -> NoteTextStyle {
    let ranked = allCases.min { lhs, rhs in
      abs(lhs.baseFont.pointSize - pointSize) < abs(rhs.baseFont.pointSize - pointSize)
    }
    return ranked ?? .body
  }
}
