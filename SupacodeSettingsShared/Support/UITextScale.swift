import AppKit
import SwiftUI

/// Carries the chrome text size to descendants. Set at each window root by
/// `appChromeTextSize`; read by `appFont`. An explicit size is required because
/// macOS SwiftUI does not resize text for Dynamic Type.
private struct UIChromeTextSizeKey: EnvironmentKey {
  static let defaultValue: ChromeTextSize = .standard
}

extension EnvironmentValues {
  var uiChromeTextSize: ChromeTextSize {
    get { self[UIChromeTextSizeKey.self] }
    set { self[UIChromeTextSizeKey.self] = newValue }
  }
}

/// Base point sizes and default weights for the semantic text styles, read once
/// from the live system fonts. The text-style table is fixed after launch, so
/// caching it keeps the scaled path off AppKit on every body evaluation.
enum AppFontMetrics {
  private static let pointSizes: [Font.TextStyle: CGFloat] = {
    let styles: [Font.TextStyle] = [
      .largeTitle, .title, .title2, .title3, .headline, .subheadline,
      .body, .callout, .footnote, .caption, .caption2,
    ]
    return Dictionary(
      uniqueKeysWithValues: styles.map {
        ($0, NSFont.preferredFont(forTextStyle: nsTextStyle(for: $0)).pointSize)
      }
    )
  }()

  static func pointSize(for style: Font.TextStyle) -> CGFloat {
    pointSizes[style] ?? NSFont.preferredFont(forTextStyle: .body).pointSize
  }

  /// The semantic style's default weight, preserved when the caller doesn't
  /// override it. Only `.headline` deviates from regular on macOS.
  static func defaultWeight(for style: Font.TextStyle) -> Font.Weight {
    style == .headline ? .semibold : .regular
  }

  /// Rounded scaled point size. A fractional size gives a fractional line
  /// height, which drifts baselines across the sidebar's dense rows.
  static func scaledPointSize(for style: Font.TextStyle, size: ChromeTextSize) -> CGFloat {
    (pointSize(for: style) * size.scale).rounded()
  }

  /// The font `appFont` applies. At `.standard` it returns the exact semantic
  /// font so Default text is left untouched.
  static func resolvedFont(
    for style: Font.TextStyle, size: ChromeTextSize, weight: Font.Weight?, monospaced: Bool
  ) -> Font {
    guard size != .standard else {
      var font = Font.system(style)
      if let weight { font = font.weight(weight) }
      if monospaced { font = font.monospaced() }
      return font
    }
    let scaledSize = scaledPointSize(for: style, size: size)
    // Only name the design when monospaced; the default carries no design box,
    // so `.system(size:)` stays the canonical form for regular text.
    let font = monospaced ? Font.system(size: scaledSize, design: .monospaced) : Font.system(size: scaledSize)
    return font.weight(weight ?? defaultWeight(for: style))
  }

  /// The font `appFontInheriting` applies, or `nil` at `.standard` to leave the
  /// container's own styling in place.
  static func inheritedFont(
    for base: Font.TextStyle, size: ChromeTextSize, weight: Font.Weight?
  ) -> Font? {
    guard size != .standard else { return nil }
    return Font.system(size: scaledPointSize(for: base, size: size))
      .weight(weight ?? defaultWeight(for: base))
  }

  /// Scaled base font for a bounded container, or `nil` at `.standard`. Raising
  /// the environment font lets a `Form` derive its own label hierarchy from a
  /// larger base, so implicit text scales without a per-label opt-in.
  static func baseFont(for size: ChromeTextSize) -> Font? {
    guard size != .standard else { return nil }
    return Font.system(size: scaledPointSize(for: .body, size: size))
  }

  private static func nsTextStyle(for style: Font.TextStyle) -> NSFont.TextStyle {
    switch style {
    case .largeTitle: .largeTitle
    case .title: .title1
    case .title2: .title2
    case .title3: .title3
    case .headline: .headline
    case .subheadline: .subheadline
    case .body: .body
    case .callout: .callout
    case .footnote: .footnote
    case .caption: .caption1
    case .caption2: .caption2
    @unknown default: .body
    }
  }
}

private struct AppFontModifier: ViewModifier {
  @Environment(\.uiChromeTextSize) private var size
  let style: Font.TextStyle
  let weight: Font.Weight?
  let monospaced: Bool

  func body(content: Content) -> some View {
    content.font(AppFontMetrics.resolvedFont(for: style, size: size, weight: weight, monospaced: monospaced))
  }
}

/// Scales text that has no font of its own, such as a `List` section header.
/// `List` styles its headers and SwiftUI does not expose the font it resolved,
/// so `base` stands in for it above Default.
private struct AppFontInheritedModifier: ViewModifier {
  @Environment(\.uiChromeTextSize) private var size
  let base: Font.TextStyle
  let weight: Font.Weight?

  func body(content: Content) -> some View {
    if let font = AppFontMetrics.inheritedFont(for: base, size: size, weight: weight) {
      content.font(font)
    } else {
      content
    }
  }
}

extension View {
  /// Publishes the chrome text size to descendants. Applied at each window root;
  /// text opts in with `appFont`.
  public func appChromeTextSize(_ size: ChromeTextSize) -> some View {
    environment(\.uiChromeTextSize, size)
  }

  /// Raises the base font for a bounded container whose text is mostly implicit
  /// (the Settings and reference windows, built from `Form`/`Picker`/`Toggle`
  /// labels that never call `appFont`). Left untouched at Default. Do not apply
  /// to the main window, whose chrome opts in explicitly through `appFont`.
  public func appChromeBaseFont(_ size: ChromeTextSize) -> some View {
    environment(\.font, AppFontMetrics.baseFont(for: size))
  }

  /// Applies a semantic text style that honors the chrome text size. Use in
  /// place of `.font(.body)` for chrome text that should follow the chosen size.
  /// `weight` overrides the style's default weight; `monospaced` picks the
  /// monospaced design.
  public func appFont(_ style: Font.TextStyle, weight: Font.Weight? = nil, monospaced: Bool = false) -> some View {
    modifier(AppFontModifier(style: style, weight: weight, monospaced: monospaced))
  }

  /// Scales text whose font comes from an enclosing container rather than this
  /// view, such as the sidebar's `Section` headers. At Default the container's
  /// styling is left in place; `base` sets the point size it grows from above that.
  public func appFontInheriting(_ base: Font.TextStyle, weight: Font.Weight? = nil) -> some View {
    modifier(AppFontInheritedModifier(base: base, weight: weight))
  }
}
