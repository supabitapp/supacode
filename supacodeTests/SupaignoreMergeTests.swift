import Testing

@testable import SupacodeSettingsShared

struct SupaignoreMergeTests {
  @Test func returnsNilWhenAllSourcesAbsent() {
    #expect(SupaignoreMerge.merged(global: nil, repoDefault: nil, committed: nil) == nil)
  }

  @Test func returnsNilWhenSourcesAreBlank() {
    #expect(SupaignoreMerge.merged(global: "  \n", repoDefault: "\n\n", committed: nil) == nil)
  }

  @Test func returnsNilForCommentOnlySources() {
    // Genuine comments have `#` at column 0 (a leading space would make it a
    // pattern), see treatsLeadingSpaceHashAsPatternNotComment.
    #expect(SupaignoreMerge.merged(global: "# a comment\n", repoDefault: nil, committed: "# b\n") == nil)
  }

  @Test func mergesPresentSourcesInSpecificityOrder() {
    let merged = SupaignoreMerge.merged(
      global: "*.log",
      repoDefault: "build/",
      committed: "node_modules/"
    )
    #expect(merged == "*.log\nbuild/\nnode_modules/\n")
  }

  @Test func skipsAbsentLevelsButKeepsOrder() {
    let merged = SupaignoreMerge.merged(global: "*.log", repoDefault: nil, committed: "!keep.log")
    #expect(merged == "*.log\n!keep.log\n")
  }

  @Test func insertsSeparatorSoTrailingNewlineIsNeverRequired() {
    // A source saved without a trailing newline must not fuse into the next
    // level's first pattern (which would corrupt both into one pattern that
    // matches nothing).
    let merged = SupaignoreMerge.merged(global: "*.env", repoDefault: "!keep.env", committed: nil)
    #expect(merged == "*.env\n!keep.env\n")
  }

  @Test func treatsLeadingSpaceHashAsPatternNotComment() {
    // `#` is a comment only at column 0; ` #secret` is a valid pattern for a
    // filename beginning with a space, so it must not be dropped as a comment.
    let merged = SupaignoreMerge.merged(global: " #secret", repoDefault: nil, committed: nil)
    #expect(merged == " #secret\n")
  }

  @Test func preservesSignificantPatternWhitespace() {
    // A filename ending in a space is escaped as `secret\ `; blanket trimming
    // would corrupt the pattern.
    let merged = SupaignoreMerge.merged(global: "secret\\ ", repoDefault: nil, committed: nil)
    #expect(merged == "secret\\ \n")
  }

  @Test func keepsEffectiveWhenOnlyOneSourceHasAPattern() {
    let merged = SupaignoreMerge.merged(global: "# only comments\n", repoDefault: "dist/", committed: "\n")
    #expect(merged == "# only comments\ndist/\n")
  }
}
