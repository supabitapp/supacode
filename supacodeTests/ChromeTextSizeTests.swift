import SwiftUI
import Testing

@testable import SupacodeSettingsShared

struct ChromeTextSizeTests {
  @Test func defaultIsTheUnmodifiedSystemSize() {
    #expect(ChromeTextSize.default == .standard)
    #expect(ChromeTextSize.default.scale == 1.0)
  }

  @Test func sizesGrowMonotonically() {
    let scales = ChromeTextSize.allCases.map(\.scale)
    #expect(scales == scales.sorted())
    #expect(Set(scales).count == scales.count)
  }

  @Test func casesAreOrderedSmallestFirst() {
    // `allCases` is the order the picker renders, so reordering the cases
    // reorders the control.
    #expect(ChromeTextSize.allCases == [.standard, .large, .extraLarge])
    #expect(ChromeTextSize.allCases.first == .default)
  }

  @Test func rawValuesAreStableAcrossReleases() {
    // The raw values are the on-disk representation in the settings file;
    // renaming one silently resets a user's chosen size back to the default.
    #expect(ChromeTextSize.standard.rawValue == "standard")
    #expect(ChromeTextSize.large.rawValue == "large")
    #expect(ChromeTextSize.extraLarge.rawValue == "extraLarge")
  }
}

/// The font-resolution core behind `appFont` / `appFontInheriting`. Extracted
/// from the view modifiers so the size math is testable without a view host.
struct AppFontMetricsTests {
  @Test func standardResolvesToTheExactSemanticFont() {
    // The Default path must leave text byte-identical to `.font(...)`, so no
    // scaled point size is substituted.
    #expect(AppFontMetrics.resolvedFont(for: .body, size: .standard, weight: nil, monospaced: false) == .system(.body))
    #expect(
      AppFontMetrics.resolvedFont(for: .body, size: .standard, weight: .semibold, monospaced: false)
        == .system(.body).weight(.semibold)
    )
    #expect(
      AppFontMetrics.resolvedFont(for: .body, size: .standard, weight: nil, monospaced: true)
        == .system(.body).monospaced()
    )
  }

  @Test func scaledPathRoundsAndKeepsTheStyleDefaultWeight() {
    let size = AppFontMetrics.scaledPointSize(for: .body, size: .large)
    #expect(size == size.rounded())
    #expect(
      AppFontMetrics.resolvedFont(for: .body, size: .large, weight: nil, monospaced: false)
        == .system(size: size).weight(.regular)
    )
  }

  @Test func headlineKeepsSemiboldWhenScaled() {
    // `.headline` is the one macOS style that isn't regular; the scaled path
    // re-applies the weight explicitly, so it must preserve it.
    let size = AppFontMetrics.scaledPointSize(for: .headline, size: .extraLarge)
    #expect(
      AppFontMetrics.resolvedFont(for: .headline, size: .extraLarge, weight: nil, monospaced: false)
        == .system(size: size).weight(.semibold)
    )
    #expect(AppFontMetrics.defaultWeight(for: .headline) == .semibold)
    #expect(AppFontMetrics.defaultWeight(for: .body) == .regular)
  }

  @Test func scaledPointSizeGrowsWithTheSize() {
    let standard = AppFontMetrics.scaledPointSize(for: .body, size: .standard)
    let large = AppFontMetrics.scaledPointSize(for: .body, size: .large)
    let extraLarge = AppFontMetrics.scaledPointSize(for: .body, size: .extraLarge)
    #expect(standard <= large)
    #expect(large <= extraLarge)
    #expect(standard < extraLarge)
  }

  @Test func inheritedFontIsAbsentAtDefaultAndPresentAbove() {
    #expect(AppFontMetrics.inheritedFont(for: .subheadline, size: .standard, weight: nil) == nil)
    #expect(AppFontMetrics.inheritedFont(for: .subheadline, size: .large, weight: .semibold) != nil)
  }
}
