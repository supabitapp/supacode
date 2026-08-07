import SwiftUI
import Testing

@testable import supacode

@MainActor
struct TerminalRenderingPolicyTests {
  @Test func surfaceActivityForSelectedVisibleFocusedSurfaceIsFocused() {
    let focusedID = UUID()
    let activity = WorktreeTerminalState.surfaceActivity(
      isSurfaceVisibleInTree: true,
      isWorktreeSelected: true,
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
    let activity = WorktreeTerminalState.surfaceActivity(
      isSurfaceVisibleInTree: true,
      isWorktreeSelected: true,
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
    let activity = WorktreeTerminalState.surfaceActivity(
      isSurfaceVisibleInTree: true,
      isWorktreeSelected: true,
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
    let activity = WorktreeTerminalState.surfaceActivity(
      isSurfaceVisibleInTree: true,
      isWorktreeSelected: true,
      isSelectedTab: true,
      windowIsVisible: false,
      windowIsKey: true,
      focusedSurfaceID: surfaceID,
      surfaceID: surfaceID
    )
    #expect(!activity.isVisible)
    #expect(!activity.isFocused)
  }

  @Test func surfaceActivityForUnknownWindowVisibilityFailsOpen() {
    let surfaceID = UUID()
    let activity = WorktreeTerminalState.surfaceActivity(
      isSurfaceVisibleInTree: true,
      isWorktreeSelected: true,
      isSelectedTab: true,
      windowIsVisible: nil,
      windowIsKey: false,
      focusedSurfaceID: surfaceID,
      surfaceID: surfaceID
    )
    #expect(activity.isVisible)
    #expect(!activity.isFocused)
  }

  @Test func surfaceActivityForUnselectedWorktreeIsHiddenAndUnfocused() {
    let surfaceID = UUID()
    let activity = WorktreeTerminalState.surfaceActivity(
      isSurfaceVisibleInTree: true,
      isWorktreeSelected: false,
      isSelectedTab: true,
      windowIsVisible: true,
      windowIsKey: true,
      focusedSurfaceID: surfaceID,
      surfaceID: surfaceID
    )
    #expect(!activity.isVisible)
    #expect(!activity.isFocused)
  }

  @Test func surfaceActivityForUnselectedTabIsHiddenAndUnfocused() {
    let surfaceID = UUID()
    let activity = WorktreeTerminalState.surfaceActivity(
      isSurfaceVisibleInTree: true,
      isWorktreeSelected: true,
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
    let activity = WorktreeTerminalState.surfaceActivity(
      isSurfaceVisibleInTree: false,
      isWorktreeSelected: true,
      isSelectedTab: true,
      windowIsVisible: true,
      windowIsKey: true,
      focusedSurfaceID: surfaceID,
      surfaceID: surfaceID
    )
    #expect(!activity.isVisible)
    #expect(!activity.isFocused)
  }

  @Test func resizeSkipsOnlySizesThatWereActuallyApplied() {
    let applied = CGSize(width: 1600, height: 1200)
    let decision = GhosttySurfaceView.ResizePolicy.decision(
      backingSize: applied,
      lastAppliedBackingSize: applied,
      cellWidth: 10,
      cellHeight: 20
    )
    #expect(decision == .skipUnchanged)
  }

  @Test func resizeRejectsDegenerateGridWithoutRecordingIt() {
    let degenerate = CGSize(width: 48, height: 30)
    let decision = GhosttySurfaceView.ResizePolicy.decision(
      backingSize: degenerate,
      lastAppliedBackingSize: CGSize(width: 1600, height: 1200),
      cellWidth: 10,
      cellHeight: 20
    )
    #expect(decision == .rejectDegenerate)
  }

  @Test func resizeBackToPreviouslyRejectedSizeAppliesOnceGridIsViable() {
    // Regression: the old code recorded a rejected size as applied, so a later
    // legitimate resize to the same backing size was skipped forever.
    let size = CGSize(width: 48, height: 40)
    let lastApplied = CGSize(width: 1600, height: 1200)
    let rejected = GhosttySurfaceView.ResizePolicy.decision(
      backingSize: size,
      lastAppliedBackingSize: lastApplied,
      cellWidth: 10,
      cellHeight: 20
    )
    #expect(rejected == .rejectDegenerate)
    let retried = GhosttySurfaceView.ResizePolicy.decision(
      backingSize: size,
      lastAppliedBackingSize: lastApplied,
      cellWidth: 8,
      cellHeight: 16
    )
    #expect(retried == .apply)
  }

  @Test func resizeWithUnknownCellMetricsAlwaysApplies() {
    let decision = GhosttySurfaceView.ResizePolicy.decision(
      backingSize: CGSize(width: 2, height: 2),
      lastAppliedBackingSize: .zero,
      cellWidth: 0,
      cellHeight: 0
    )
    #expect(decision == .apply)
  }

  @Test func resizeWithOnlyOneUnknownCellDimensionStillApplies() {
    // Each half of the cell-metric guard must independently short-circuit, or the
    // divisions below it would divide by zero.
    let unknownHeight = GhosttySurfaceView.ResizePolicy.decision(
      backingSize: CGSize(width: 800, height: 600),
      lastAppliedBackingSize: .zero,
      cellWidth: 10,
      cellHeight: 0
    )
    #expect(unknownHeight == .apply)
    let unknownWidth = GhosttySurfaceView.ResizePolicy.decision(
      backingSize: CGSize(width: 800, height: 600),
      lastAppliedBackingSize: .zero,
      cellWidth: 0,
      cellHeight: 20
    )
    #expect(unknownWidth == .apply)
  }

  @Test func resizeRejectsWhenOnlyColumnsAreBelowMinimum() {
    let decision = GhosttySurfaceView.ResizePolicy.decision(
      backingSize: CGSize(width: 49, height: 100),
      lastAppliedBackingSize: .zero,
      cellWidth: 10,
      cellHeight: 20
    )
    #expect(decision == .rejectDegenerate)
  }

  @Test func resizeRejectsWhenOnlyRowsAreBelowMinimum() {
    let decision = GhosttySurfaceView.ResizePolicy.decision(
      backingSize: CGSize(width: 100, height: 39),
      lastAppliedBackingSize: .zero,
      cellWidth: 10,
      cellHeight: 20
    )
    #expect(decision == .rejectDegenerate)
  }

  @Test func resizeAppliesAtExactMinimumGrid() {
    let decision = GhosttySurfaceView.ResizePolicy.decision(
      backingSize: CGSize(width: 50, height: 40),
      lastAppliedBackingSize: .zero,
      cellWidth: 10,
      cellHeight: 20
    )
    #expect(decision == .apply)
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
