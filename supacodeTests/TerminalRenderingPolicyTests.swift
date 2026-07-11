import SwiftUI
import Testing

@testable import supacode

@MainActor
struct TerminalRenderingPolicyTests {
  @Test func surfaceActivityForSelectedVisibleFocusedSurfaceIsFocused() {
    let focusedID = UUID()
    let activity = WorktreeSurfaceState.surfaceActivity(
      isSurfaceVisibleInTree: true,
      isSelectedTab: true,
      windowIsVisible: true,
      windowIsKey: true,
      focusedSurfaceID: focusedID,
      surfaceID: focusedID
    )
    #expect(activity.isVisible)
    #expect(activity.isFocused)
  }

  @Test func surfaceActivityForSelectedVisibleUnfocusedSurfaceIsNotFocused() {
    let activity = WorktreeSurfaceState.surfaceActivity(
      isSurfaceVisibleInTree: true,
      isSelectedTab: true,
      windowIsVisible: true,
      windowIsKey: true,
      focusedSurfaceID: UUID(),
      surfaceID: UUID()
    )
    #expect(activity.isVisible)
    #expect(!activity.isFocused)
  }

  @Test func surfaceActivityForSelectedTabInBackgroundWindowIsVisibleButNotFocused() {
    let surfaceID = UUID()
    let activity = WorktreeSurfaceState.surfaceActivity(
      isSurfaceVisibleInTree: true,
      isSelectedTab: true,
      windowIsVisible: true,
      windowIsKey: false,
      focusedSurfaceID: surfaceID,
      surfaceID: surfaceID
    )
    #expect(activity.isVisible)
    #expect(!activity.isFocused)
  }

  @Test func surfaceActivityForOccludedWindowIsHiddenAndUnfocused() {
    let surfaceID = UUID()
    let activity = WorktreeSurfaceState.surfaceActivity(
      isSurfaceVisibleInTree: true,
      isSelectedTab: true,
      windowIsVisible: false,
      windowIsKey: true,
      focusedSurfaceID: surfaceID,
      surfaceID: surfaceID
    )
    #expect(!activity.isVisible)
    #expect(!activity.isFocused)
  }

  @Test func surfaceActivityForUnselectedTabIsHiddenAndUnfocused() {
    let surfaceID = UUID()
    let activity = WorktreeSurfaceState.surfaceActivity(
      isSurfaceVisibleInTree: true,
      isSelectedTab: false,
      windowIsVisible: true,
      windowIsKey: true,
      focusedSurfaceID: surfaceID,
      surfaceID: surfaceID
    )
    #expect(!activity.isVisible)
    #expect(!activity.isFocused)
  }

  @Test func surfaceActivityForZoomHiddenSurfaceIsHiddenAndUnfocused() {
    let surfaceID = UUID()
    let activity = WorktreeSurfaceState.surfaceActivity(
      isSurfaceVisibleInTree: false,
      isSelectedTab: true,
      windowIsVisible: true,
      windowIsKey: true,
      focusedSurfaceID: surfaceID,
      surfaceID: surfaceID
    )
    #expect(!activity.isVisible)
    #expect(!activity.isFocused)
  }

  @Test func tabContentStackReturnsSelectedTabWhenItExists() {
    let selected = TerminalTabID()
    let tabs = [
      TerminalTabItem(title: "one", icon: nil),
      TerminalTabItem(id: selected, title: "two", icon: nil),
    ]
    let selectedTab = TerminalTabContentStack<EmptyView>.selectedTabID(
      in: tabs,
      selectedTabId: selected
    )
    #expect(selectedTab == selected)
  }

  @Test func tabContentStackReturnsNilWhenSelectionDoesNotExist() {
    let selected = TerminalTabID()
    let tabs = [
      TerminalTabItem(title: "one", icon: nil),
      TerminalTabItem(title: "two", icon: nil),
    ]
    let selectedTab = TerminalTabContentStack<EmptyView>.selectedTabID(
      in: tabs,
      selectedTabId: selected
    )
    #expect(selectedTab == nil)
  }
}
