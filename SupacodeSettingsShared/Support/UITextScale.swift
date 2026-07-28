import AppKit
import SwiftUI

/// Environment carrier for the app-wide UI text scale (1.0 = system default).
/// Set at each window root from `GlobalSettings.chromeTextSize`; read by
/// `View.appFont(_:)`. Using an explicit scale (rather than `dynamicTypeSize`)
/// is required because macOS SwiftUI does not resize text for Dynamic Type.
///
/// Lives in the shared module so every UI module (app + settings feature) routes
/// its chrome text through the same helper.
private struct UITextScaleKey: EnvironmentKey {
  static let defaultValue: Double = 1.0
}

extension EnvironmentValues {
  public var uiTextScale: Double {
    get { self[UITextScaleKey.self] }
    set { self[UITextScaleKey.self] = newValue }
  }
}

/// Base point sizes and default weights for the semantic text styles, read from
/// the live system fonts so scaled sizes track the platform instead of a
/// hardcoded table. Read once: macOS resolves the text-style table at launch and
/// does not change it while the app runs, and the scaled path would otherwise
/// hit AppKit on every body evaluation of every scaled view.
private enum AppFontMetrics {
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
  @Environment(\.uiTextScale) private var scale
  let style: Font.TextStyle
  let weight: Font.Weight?
  let monospaced: Bool

  func body(content: Content) -> some View {
    content.font(resolvedFont)
  }

  private var resolvedFont: Font {
    // At 1.0× use the exact semantic font, so Default leaves text untouched.
    if scale == 1.0 {
      var font = Font.system(style)
      if let weight { font = font.weight(weight) }
      if monospaced { font = font.monospaced() }
      return font
    }
    // Rounded: a fractional point size gives a fractional line height, which
    // drifts baselines across the sidebar's dense rows.
    let scaledSize = (AppFontMetrics.pointSize(for: style) * scale).rounded()
    let font = Font.system(size: scaledSize, design: monospaced ? .monospaced : .default)
    return font.weight(weight ?? AppFontMetrics.defaultWeight(for: style))
  }
}

/// Scales text that has no font of its own. `List` styles its own section
/// headers and SwiftUI does not expose the font it resolved, so there is nothing
/// to scale in place — `base` stands in for it. At 1.0× the view is left alone,
/// which keeps the platform header styling as it ships.
private struct AppFontInheritedModifier: ViewModifier {
  @Environment(\.uiTextScale) private var scale
  let base: Font.TextStyle
  let weight: Font.Weight?

  func body(content: Content) -> some View {
    if scale == 1.0 {
      content
    } else {
      content.font(
        Font.system(size: (AppFontMetrics.pointSize(for: base) * scale).rounded())
          .weight(weight ?? AppFontMetrics.defaultWeight(for: base))
      )
    }
  }
}

extension View {
  /// Publishes the chrome text size to descendants. Applied at each window root;
  /// text opts in with `.appFont(_:)`.
  public func appChromeTextSize(_ size: ChromeTextSize) -> some View {
    environment(\.uiTextScale, size.scale)
  }

  /// Applies a semantic text style that honors the chrome text size. Use this in
  /// place of `.font(.body)` etc. for chrome text that should follow the user's
  /// chosen size. `weight` overrides the style's default weight; `monospaced`
  /// picks the monospaced design.
  public func appFont(_ style: Font.TextStyle, weight: Font.Weight? = nil, monospaced: Bool = false) -> some View {
    modifier(AppFontModifier(style: style, weight: weight, monospaced: monospaced))
  }

  /// Scales text whose font comes from an enclosing container rather than from
  /// this view — the sidebar's `Section` headers. At 1.0× the container's
  /// styling is left in place; `base` only sets the point size the text grows
  /// from above that.
  public func appFontInheriting(_ base: Font.TextStyle, weight: Font.Weight? = nil) -> some View {
    modifier(AppFontInheritedModifier(base: base, weight: weight))
  }
}
