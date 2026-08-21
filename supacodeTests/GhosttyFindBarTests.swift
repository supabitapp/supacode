import Testing

@testable import supacode

struct GhosttyFindBarTests {
  @Test func selectedMatchIsOneBased() {
    #expect(TerminalFindBar.matchCountText(selected: 0, total: 12) == "1/12")
    #expect(TerminalFindBar.matchCountText(selected: 4, total: 5) == "5/5")
  }

  @Test func totalWithoutSelectionShowsDash() {
    #expect(TerminalFindBar.matchCountText(selected: nil, total: 3) == "-/3")
  }

  @Test func noTotalShowsNothing() {
    #expect(TerminalFindBar.matchCountText(selected: nil, total: nil) == nil)
    #expect(TerminalFindBar.matchCountText(selected: 2, total: nil) == nil)
  }
}
