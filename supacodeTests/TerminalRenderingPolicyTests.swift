import SwiftUI
import Testing

@testable import supacode

@MainActor
struct TerminalRenderingPolicyTests {
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

}
