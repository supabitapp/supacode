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
