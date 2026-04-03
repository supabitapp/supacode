import SwiftUI
import Testing

@testable import supacode

@MainActor
struct TerminalRenderingPolicyTests {
  private func renderContext(
    isSelectedTab: Bool = true,
    windowIsVisible: Bool = true,
    windowIsKey: Bool = true,
    focusedSurfaceID: UUID?,
    firstResponderSurfaceID: UUID?
  ) -> WorktreeTerminalState.SurfaceRenderContext {
    WorktreeTerminalState.SurfaceRenderContext(
      isSelectedTab: isSelectedTab,
      windowIsVisible: windowIsVisible,
      windowIsKey: windowIsKey,
      focusedSurfaceID: focusedSurfaceID,
      firstResponderSurfaceID: firstResponderSurfaceID
    )
  }

  @Test func surfaceActivityForSelectedVisibleFocusedSurfaceIsFocused() {
    let focusedID = UUID()
    let activity = WorktreeTerminalState.surfaceActivity(
      isSurfaceVisibleInTree: true,
      renderContext: renderContext(
        focusedSurfaceID: focusedID,
        firstResponderSurfaceID: focusedID
      ),
      surfaceID: focusedID
    )
    #expect(activity.isVisible)
    #expect(activity.isFocused)
  }

  @Test func surfaceActivityForSelectedVisibleUnfocusedSurfaceIsNotFocused() {
    let activity = WorktreeTerminalState.surfaceActivity(
      isSurfaceVisibleInTree: true,
      renderContext: renderContext(
        focusedSurfaceID: UUID(),
        firstResponderSurfaceID: UUID()
      ),
      surfaceID: UUID()
    )
    #expect(activity.isVisible)
    #expect(!activity.isFocused)
  }

  @Test func surfaceActivityForSelectedTabInBackgroundWindowIsVisibleButNotFocused() {
    let surfaceID = UUID()
    let activity = WorktreeTerminalState.surfaceActivity(
      isSurfaceVisibleInTree: true,
      renderContext: renderContext(
        windowIsKey: false,
        focusedSurfaceID: surfaceID,
        firstResponderSurfaceID: surfaceID
      ),
      surfaceID: surfaceID
    )
    #expect(activity.isVisible)
    #expect(!activity.isFocused)
  }

  @Test func surfaceActivityForOccludedWindowIsHiddenAndUnfocused() {
    let surfaceID = UUID()
    let activity = WorktreeTerminalState.surfaceActivity(
      isSurfaceVisibleInTree: true,
      renderContext: renderContext(
        windowIsVisible: false,
        focusedSurfaceID: surfaceID,
        firstResponderSurfaceID: surfaceID
      ),
      surfaceID: surfaceID
    )
    #expect(!activity.isVisible)
    #expect(!activity.isFocused)
  }

  @Test func surfaceActivityForUnselectedTabIsHiddenAndUnfocused() {
    let surfaceID = UUID()
    let activity = WorktreeTerminalState.surfaceActivity(
      isSurfaceVisibleInTree: true,
      renderContext: renderContext(
        isSelectedTab: false,
        focusedSurfaceID: surfaceID,
        firstResponderSurfaceID: surfaceID
      ),
      surfaceID: surfaceID
    )
    #expect(!activity.isVisible)
    #expect(!activity.isFocused)
  }

  @Test func surfaceActivityForZoomHiddenSurfaceIsHiddenAndUnfocused() {
    let surfaceID = UUID()
    let activity = WorktreeTerminalState.surfaceActivity(
      isSurfaceVisibleInTree: false,
      renderContext: renderContext(
        focusedSurfaceID: surfaceID,
        firstResponderSurfaceID: surfaceID
      ),
      surfaceID: surfaceID
    )
    #expect(!activity.isVisible)
    #expect(!activity.isFocused)
  }

  @Test func surfaceActivityRequiresTerminalFirstResponderToMatchFocusIntent() {
    let intendedSurfaceID = UUID()
    let activity = WorktreeTerminalState.surfaceActivity(
      isSurfaceVisibleInTree: true,
      renderContext: renderContext(
        focusedSurfaceID: intendedSurfaceID,
        firstResponderSurfaceID: nil
      ),
      surfaceID: intendedSurfaceID
    )

    #expect(activity.isVisible)
    #expect(!activity.isFocused)
  }

  @Test func surfaceActivityDoesNotFocusWhenSiblingPaneOwnsFirstResponder() {
    let intendedSurfaceID = UUID()
    let siblingSurfaceID = UUID()
    let activity = WorktreeTerminalState.surfaceActivity(
      isSurfaceVisibleInTree: true,
      renderContext: renderContext(
        focusedSurfaceID: intendedSurfaceID,
        firstResponderSurfaceID: siblingSurfaceID
      ),
      surfaceID: intendedSurfaceID
    )

    #expect(activity.isVisible)
    #expect(!activity.isFocused)
  }

  @Test func worktreeSwitchWithoutTerminalAutoFocusKeepsAllVisiblePanesUnfocused() {
    let intendedSurfaceID = UUID()
    let siblingSurfaceID = UUID()

    let intendedActivity = WorktreeTerminalState.surfaceActivity(
      isSurfaceVisibleInTree: true,
      renderContext: renderContext(
        focusedSurfaceID: intendedSurfaceID,
        firstResponderSurfaceID: nil
      ),
      surfaceID: intendedSurfaceID
    )
    let siblingActivity = WorktreeTerminalState.surfaceActivity(
      isSurfaceVisibleInTree: true,
      renderContext: renderContext(
        focusedSurfaceID: intendedSurfaceID,
        firstResponderSurfaceID: nil
      ),
      surfaceID: siblingSurfaceID
    )

    #expect(intendedActivity.isVisible)
    #expect(!intendedActivity.isFocused)
    #expect(siblingActivity.isVisible)
    #expect(!siblingActivity.isFocused)
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
