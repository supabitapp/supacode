import Testing

@testable import supacode

struct GlobalHotkeyToggleTests {
  @Test func hidesOnlyWhenActiveAndShowingMainWindow() {
    #expect(GlobalHotkeyToggle.resolve(isActive: true, hasVisibleMain: true) == .hide)
  }

  @Test func showsWhenActiveButNoVisibleMainWindow() {
    #expect(GlobalHotkeyToggle.resolve(isActive: true, hasVisibleMain: false) == .show)
  }

  @Test func showsWhenInactiveWithVisibleWindowBehind() {
    #expect(GlobalHotkeyToggle.resolve(isActive: false, hasVisibleMain: true) == .show)
  }

  @Test func showsWhenInactiveAndNothingVisible() {
    #expect(GlobalHotkeyToggle.resolve(isActive: false, hasVisibleMain: false) == .show)
  }
}
