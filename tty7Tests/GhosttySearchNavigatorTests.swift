import Testing

@testable import tty7

struct GhosttySearchNavigatorTests {
  @Test func nextWrapsFromLastToFirst() {
    let actions = GhosttySearchNavigator.bindingActions(
      direction: .next,
      selected: 4,
      total: 5
    )

    #expect(actions == Array(repeating: "navigate_search:previous", count: 4))
  }

  @Test func previousWrapsFromFirstToLast() {
    let actions = GhosttySearchNavigator.bindingActions(
      direction: .previous,
      selected: 0,
      total: 5
    )

    #expect(actions == Array(repeating: "navigate_search:next", count: 4))
  }

  @Test func nonBoundaryUsesDirectAction() {
    let actions = GhosttySearchNavigator.bindingActions(
      direction: .next,
      selected: 1,
      total: 5
    )

    #expect(actions == ["navigate_search:next"])
  }

  @Test func unknownSelectionUsesDirectAction() {
    let actions = GhosttySearchNavigator.bindingActions(
      direction: .next,
      selected: nil,
      total: 5
    )

    #expect(actions == ["navigate_search:next"])
  }
}
