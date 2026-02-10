import Testing

@testable import supacode

@MainActor
struct GitDiffStatusParserTests {
  @Test func parsesMixedEntries() {
    let output =
      "## main...origin/main\0"
      + " M Sources/App.swift\0"
      + "A  Added.swift\0"
      + "D  Deleted.swift\0"
      + "R  Old.swift\0New.swift\0"
      + "?? Untracked.swift\0"

    let entries = GitDiffStatusParser.parseStatusV1Z(output)

    #expect(entries.count == 5)
    #expect(entries[0].path == "Sources/App.swift")
    #expect(entries[0].kind == .modified)

    #expect(entries[1].path == "Added.swift")
    #expect(entries[1].kind == .added)

    #expect(entries[2].path == "Deleted.swift")
    #expect(entries[2].kind == .deleted)

    #expect(entries[3].path == "New.swift")
    #expect(entries[3].originalPath == "Old.swift")
    #expect(entries[3].kind == .renamed)

    #expect(entries[4].path == "Untracked.swift")
    #expect(entries[4].kind == .untracked)
  }
}
