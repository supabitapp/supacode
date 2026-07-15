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

  @Test func markBlockingScriptCompletedKeepsTitleAndIcon() {
    let manager = TerminalTabManager()
    let tabId = manager.createTab(
      title: "Run Script",
      icon: "play.fill",
      isTitleLocked: true,
      tintColor: .green,
      isBlockingScript: true
    )
    manager.updateDirty(tabId, isDirty: true)

    manager.markBlockingScriptCompleted(tabId)

    let after = manager.tabs.first { $0.id == tabId }
    #expect(after?.title == "Run Script")
    #expect(after?.icon == "play.fill")
    #expect(after?.isTitleLocked == true)
    #expect(after?.isBlockingScript == true)
    #expect(after?.isBlockingScriptCompleted == true)
    #expect(after?.tintColor == nil)
    #expect(after?.isDirty == false)
  }

  @Test func markBlockingScriptCompletedKeepsTitleImmutable() {
    let manager = TerminalTabManager()
    let tabId = manager.createTab(
      title: "Run Script",
      icon: "play.fill",
      isTitleLocked: true,
      isBlockingScript: true
    )

    manager.markBlockingScriptCompleted(tabId)
    manager.updateTitle(tabId, title: "should be ignored")

    #expect(manager.tabs.first { $0.id == tabId }?.title == "Run Script")
  }

  @Test func setCustomTitleOverridesDisplayTitle() {
    let manager = TerminalTabManager()
    let id = manager.createTab(title: "tab 1", icon: nil)
    manager.setCustomTitle(id, title: "my name")
    #expect(manager.tabs.first { $0.id == id }!.displayTitle == "my name")
  }

  @Test func createTabSetsNormalizedCustomTitleAtomically() {
    let manager = TerminalTabManager()
    let id = manager.createTab(title: "tab 1", customTitle: "  implement  ", icon: nil)
    #expect(manager.tabs.first { $0.id == id }!.customTitle == "implement")
    #expect(manager.tabs.first { $0.id == id }!.displayTitle == "implement")
  }

  @Test func createTabWithEmptyCustomTitleUsesLiveTitle() {
    let manager = TerminalTabManager()
    let id = manager.createTab(title: "tab 1", customTitle: "", icon: nil)
    #expect(manager.tabs.first { $0.id == id }!.customTitle == nil)
    #expect(manager.tabs.first { $0.id == id }!.displayTitle == "tab 1")
  }

  @Test func setCustomTitleDoesNotLockTitle() {
    let manager = TerminalTabManager()
    let id = manager.createTab(title: "tab 1", icon: nil)
    manager.setCustomTitle(id, title: "my name")
    #expect(manager.tabs.first { $0.id == id }!.isTitleLocked == false)
  }

  @Test func setCustomTitleIgnoresLockedTab() {
    let manager = TerminalTabManager()
    let id = manager.createTab(title: "Run Script", icon: nil, isTitleLocked: true)
    #expect(manager.setCustomTitle(id, title: "my name") == false)
    #expect(manager.tabs.first { $0.id == id }!.customTitle == nil)
  }

  @Test func createTabIgnoresCustomTitleOnLockedTab() {
    let manager = TerminalTabManager()
    let id = manager.createTab(
      title: "Run Script", customTitle: "implement", icon: nil, isTitleLocked: true)
    #expect(manager.tabs.first { $0.id == id }!.customTitle == nil)
    #expect(manager.tabs.first { $0.id == id }!.displayTitle == "Run Script")
  }

  @Test func customTitleBlanksControlCharacters() {
    let manager = TerminalTabManager()
    let id = manager.createTab(title: "tab 1", icon: nil)
    manager.setCustomTitle(id, title: "a\nb\tc\rd")
    #expect(manager.tabs.first { $0.id == id }!.customTitle == "a b c d")

    let created = manager.createTab(title: "tab 2", customTitle: "e\nf", icon: nil)
    #expect(manager.tabs.first { $0.id == created }!.customTitle == "e f")

    // Line / paragraph separators and escapes are control characters too.
    manager.setCustomTitle(id, title: "g\u{2028}h\u{1B}i")
    #expect(manager.tabs.first { $0.id == id }!.customTitle == "g h i")

    // The zero-width joiner is a format character, not a control one; it must survive.
    manager.setCustomTitle(id, title: "👨‍💻 deploy")
    #expect(manager.tabs.first { $0.id == id }!.customTitle == "👨‍💻 deploy")
  }

  @Test func customTitleOfOnlyControlWhitespaceClears() {
    let manager = TerminalTabManager()
    let id = manager.createTab(title: "tab 1", customTitle: "seed", icon: nil)
    #expect(manager.setCustomTitle(id, title: "\n\t ") == true)
    #expect(manager.tabs.first { $0.id == id }!.customTitle == nil)
  }

  @Test func canRenameRequiresExistingUnlockedTab() {
    let manager = TerminalTabManager()
    let unlockedID = manager.createTab(title: "tab 1", icon: nil)
    let lockedID = manager.createTab(title: "Run Script", icon: nil, isTitleLocked: true)

    #expect(manager.canRename(unlockedID))
    #expect(!manager.canRename(lockedID))
    #expect(!manager.canRename(TerminalTabID()))
  }

  @Test func setCustomTitleTrimsLeadingAndTrailingWhitespace() {
    let manager = TerminalTabManager()
    let id = manager.createTab(title: "tab 1", icon: nil)
    manager.setCustomTitle(id, title: "  my name  ")
    #expect(manager.tabs.first { $0.id == id }!.customTitle == "my name")
  }

  @Test func setCustomTitleWithWhitespaceOnlyClearsCustomTitle() {
    let manager = TerminalTabManager()
    let id = manager.createTab(title: "tab 1", icon: nil)
    manager.setCustomTitle(id, title: "first")
    manager.setCustomTitle(id, title: "  \n\t  ")
    #expect(manager.tabs.first { $0.id == id }!.customTitle == nil)
    #expect(manager.tabs.first { $0.id == id }!.displayTitle == "tab 1")
  }

  @Test func setCustomTitleOnUnknownTabIsNoOp() {
    let manager = TerminalTabManager()
    let id = manager.createTab(title: "tab 1", icon: nil)
    manager.setCustomTitle(TerminalTabID(), title: "my name")
    #expect(manager.tabs.first { $0.id == id }!.customTitle == nil)
  }

  @Test func ghosttyUpdateDoesNotAffectDisplayTitleWhenCustomTitleSet() {
    let manager = TerminalTabManager()
    let id = manager.createTab(title: "tab 1", icon: nil)
    manager.setCustomTitle(id, title: "my name")
    manager.updateTitle(id, title: "vim • main.swift")
    let tab = manager.tabs.first { $0.id == id }!
    #expect(tab.title == "vim • main.swift")
    #expect(tab.displayTitle == "my name")
  }

  @Test func clearingCustomTitleRestoresLiveShellTitle() {
    let manager = TerminalTabManager()
    let id = manager.createTab(title: "tab 1", icon: nil)
    manager.setCustomTitle(id, title: "my name")
    manager.updateTitle(id, title: "zsh")
    manager.setCustomTitle(id, title: "")
    #expect(manager.tabs.first { $0.id == id }!.displayTitle == "zsh")
  }

  @Test func setCustomTitleWithCurrentLiveTitlePinsIt() {
    // Manager does not treat same-value as idempotent — pins title; view-layer guard is the sole gate.
    let manager = TerminalTabManager()
    let id = manager.createTab(title: "zsh", icon: nil)
    manager.setCustomTitle(id, title: "zsh")
    manager.updateTitle(id, title: "vim")
    let tab = manager.tabs.first { $0.id == id }!
    #expect(tab.customTitle == "zsh")
    #expect(tab.displayTitle == "zsh")
  }

  @Test func ghosttyUpdateAppliedAfterCustomTitleCleared() {
    let manager = TerminalTabManager()
    let id = manager.createTab(title: "tab 1", icon: nil)
    manager.setCustomTitle(id, title: "my name")
    manager.setCustomTitle(id, title: "")
    manager.updateTitle(id, title: "vim")
    #expect(manager.tabs.first { $0.id == id }!.displayTitle == "vim")
  }

  @Test func beginTabRenameSetsEditingTabID() {
    let manager = TerminalTabManager()
    let id = manager.createTab(title: "tab 1", icon: nil)
    manager.beginTabRename(id)
    #expect(manager.editingTabID == id)
  }

  @Test func beginTabRenameIgnoresLockedTab() {
    let manager = TerminalTabManager()
    let id = manager.createTab(title: "Run Script", icon: nil, isTitleLocked: true)
    manager.beginTabRename(id)
    #expect(manager.editingTabID == nil)
  }

  @Test func closingTabClearsEditingTabID() {
    let manager = TerminalTabManager()
    let id = manager.createTab(title: "tab 1", icon: nil)
    manager.beginTabRename(id)
    manager.closeTab(id)
    #expect(manager.editingTabID == nil)
  }

  @Test func closeOthersClearsEditingTabIDForRemovedTab() {
    let manager = TerminalTabManager()
    let first = manager.createTab(title: "tab 1", icon: nil)
    let second = manager.createTab(title: "tab 2", icon: nil)
    manager.beginTabRename(first)
    manager.closeOthers(keeping: second)
    #expect(manager.editingTabID == nil)
  }

  @Test func closeToRightClearsEditingTabIDForRemovedTab() {
    let manager = TerminalTabManager()
    let first = manager.createTab(title: "tab 1", icon: nil)
    let second = manager.createTab(title: "tab 2", icon: nil)
    manager.beginTabRename(second)
    manager.closeToRight(of: first)
    #expect(manager.editingTabID == nil)
  }

  @Test func closeAllClearsEditingTabID() {
    let manager = TerminalTabManager()
    let id = manager.createTab(title: "tab 1", icon: nil)
    manager.beginTabRename(id)
    manager.closeAll()
    #expect(manager.editingTabID == nil)
  }

  @Test func closingDifferentTabPreservesEditingTabID() {
    let manager = TerminalTabManager()
    let first = manager.createTab(title: "tab 1", icon: nil)
    let second = manager.createTab(title: "tab 2", icon: nil)
    manager.beginTabRename(first)
    manager.closeTab(second)
    #expect(manager.editingTabID == first)
  }

  @Test func endTabRenameClearsEditingTabID() {
    let manager = TerminalTabManager()
    let id = manager.createTab(title: "tab 1", icon: nil)
    manager.beginTabRename(id)
    manager.endTabRename()
    #expect(manager.editingTabID == nil)
  }

  @Test func beginTabRenameIgnoresUnknownTabID() {
    let manager = TerminalTabManager()
    _ = manager.createTab(title: "tab 1", icon: nil)
    manager.beginTabRename(TerminalTabID())
    #expect(manager.editingTabID == nil)
  }
}
