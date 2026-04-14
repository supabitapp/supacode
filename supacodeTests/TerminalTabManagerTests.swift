import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct TerminalTabManagerTests {
  @Test func createTabInsertsAfterSelection() {
    let manager = TerminalTabManager()
    let first = manager.createTab(title: "one", icon: nil)
    let second = manager.createTab(title: "two", icon: nil)
    manager.selectTab(first)
    let third = manager.createTab(title: "three", icon: nil)
    let ids = manager.tabs.map(\.id)
    #expect(ids == [first, third, second])
  }

  @Test func closeTabSelectsAdjacent() {
    let manager = TerminalTabManager()
    let first = manager.createTab(title: "one", icon: nil)
    let second = manager.createTab(title: "two", icon: nil)
    let third = manager.createTab(title: "three", icon: nil)
    manager.selectTab(second)
    manager.closeTab(second)
    #expect(manager.tabs.map(\.id) == [first, third])
    #expect(manager.selectedTabId == first)
  }

  @Test func closeToRightRemovesTrailingTabs() {
    let manager = TerminalTabManager()
    let first = manager.createTab(title: "one", icon: nil)
    let second = manager.createTab(title: "two", icon: nil)
    let third = manager.createTab(title: "three", icon: nil)
    manager.closeToRight(of: second)
    #expect(manager.tabs.map(\.id) == [first, second])
    #expect(manager.tabs.contains { $0.id == third } == false)
  }

  @Test func closeOthersLeavesSingleTab() {
    let manager = TerminalTabManager()
    let first = manager.createTab(title: "one", icon: nil)
    let second = manager.createTab(title: "two", icon: nil)
    _ = manager.createTab(title: "three", icon: nil)
    manager.closeOthers(keeping: second)
    #expect(manager.tabs.map(\.id) == [second])
    #expect(manager.selectedTabId == second)
    #expect(manager.tabs.contains { $0.id == first } == false)
  }

  @Test func reorderTabsUsesProvidedOrder() {
    let manager = TerminalTabManager()
    let first = manager.createTab(title: "one", icon: nil)
    let second = manager.createTab(title: "two", icon: nil)
    let third = manager.createTab(title: "three", icon: nil)
    manager.reorderTabs([third, first, second])
    #expect(manager.tabs.map(\.id) == [third, first, second])
  }

  @Test func updateDirtyUpdatesTabState() {
    let manager = TerminalTabManager()
    let tabId = manager.createTab(title: "one", icon: nil)
    manager.updateDirty(tabId, isDirty: true)
    #expect(manager.tabs.first?.isDirty == true)
    manager.updateDirty(tabId, isDirty: false)
    #expect(manager.tabs.first?.isDirty == false)
  }

  @Test func createTabWithTintColorSetsColor() {
    let manager = TerminalTabManager()
    let tabId = manager.createTab(title: "script", icon: "play.fill", tintColor: .green)
    let tab = manager.tabs.first { $0.id == tabId }
    #expect(tab?.tintColor == .green)
    #expect(tab?.icon == "play.fill")
  }

  @Test func unlockAndUpdateTitleResetsTabToDefaults() {
    let manager = TerminalTabManager()
    let tabId = manager.createTab(
      title: "Run Script",
      icon: "play.fill",
      isTitleLocked: true,
      tintColor: .green
    )
    let before = manager.tabs.first { $0.id == tabId }
    #expect(before?.isTitleLocked == true)
    #expect(before?.icon == "play.fill")
    #expect(before?.tintColor == .green)

    manager.unlockAndUpdateTitle(tabId, title: "wt-1 2")

    let after = manager.tabs.first { $0.id == tabId }
    #expect(after?.title == "wt-1 2")
    #expect(after?.isTitleLocked == false)
    #expect(after?.icon == nil)
    #expect(after?.tintColor == nil)
  }

  @Test func unlockAndUpdateTitleAllowsSubsequentTitleUpdates() {
    let manager = TerminalTabManager()
    let tabId = manager.createTab(title: "Run Script", icon: "play.fill", isTitleLocked: true)

    manager.updateTitle(tabId, title: "should be ignored")
    #expect(manager.tabs.first { $0.id == tabId }?.title == "Run Script")

    manager.unlockAndUpdateTitle(tabId, title: "wt-1 1")
    manager.updateTitle(tabId, title: "new shell title")
    #expect(manager.tabs.first { $0.id == tabId }?.title == "new shell title")
  }
}
