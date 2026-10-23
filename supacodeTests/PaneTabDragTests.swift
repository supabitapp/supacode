import ComposableArchitecture
import Foundation
import Testing

@testable import supacode

@MainActor
struct PaneTabDragTests {
  private struct Fixture {
    let store: StoreOf<LayoutFeature>
    let pane: Pane
    let tabID: TabID
  }

  private func makeFixture() -> Fixture {
    let paneID = PaneID()
    let tabID = TabID()
    let pane = Pane(
      id: paneID,
      tabs: [
        TabItem(
          id: tabID,
          title: "Tab",
          content: ContentSnapshot(id: ContentID(), state: .terminal(TerminalContentState(workingDirectory: nil)))
        )
      ],
      selectedTabID: tabID
    )
    let layout = PaneLayout(tree: SplitTree(view: paneID), panes: [pane], focusedPaneID: paneID)
    let store = Store(initialState: LayoutFeature.State(id: WorktreeID("/tmp/pane-tab-drag"), layout: layout)) {
      LayoutFeature()
    }
    return Fixture(store: store, pane: pane, tabID: tabID)
  }

  // The drag session repeats its start on every update; the span highlight must survive that.
  @Test func repeatedStartForTheSameTabKeepsTheSpanTarget() {
    let dragModel = PaneTabDragModel()
    let tabID = TabID()
    let target = PaneTabDragModel.SpanTarget(anchorPaneID: PaneID(), direction: .right)

    dragModel.startDrag(from: tabID)
    dragModel.spanTarget = target
    dragModel.startDrag(from: tabID)
    #expect(dragModel.spanTarget == target)

    dragModel.startDrag(from: TabID())
    #expect(dragModel.spanTarget == nil)
  }

  @Test func tabDragIsActiveFromStartUntilReset() {
    let dragModel = PaneTabDragModel()
    #expect(!dragModel.isDraggingTab)

    dragModel.startDrag(from: TabID())
    #expect(dragModel.isDraggingTab)

    dragModel.reset()
    #expect(!dragModel.isDraggingTab)
  }

  // #836: a lingering drag keeps the split zones over the terminal, so even refused drops must end it.
  // An empty payload is refused before the store is read, so this pins the reset-first ordering.
  @Test func refusedDropsStillEndTheTabDrag() {
    let fixture = makeFixture()
    let dragModel = PaneTabDragModel()

    dragModel.startDrag(from: fixture.tabID)
    #expect(!PaneTabDrag.performDrop([], into: fixture.pane, at: 0, store: fixture.store, dragModel: dragModel))
    #expect(!dragModel.isDraggingTab)

    dragModel.startDrag(from: fixture.tabID)
    #expect(
      !PaneTabDrag.performSplitDrop(
        [], anchor: fixture.pane, direction: .right, store: fixture.store, dragModel: dragModel)
    )
    #expect(!dragModel.isDraggingTab)

    dragModel.startDrag(from: fixture.tabID)
    #expect(
      !PaneTabDrag.performSpanningSplitDrop(
        [], anchor: fixture.pane, direction: .right, store: fixture.store, dragModel: dragModel)
    )
    #expect(!dragModel.isDraggingTab)
  }

  // Pane windows and the main layout must share one model,
  // or a tab dragged out of a pane window never mounts the zones.
  @Test func defaultRenderContextUsesTheSharedDragModel() {
    #expect(PaneRenderContext(runtime: ContentRuntime()).dragModel === PaneTabDragModel.shared)
  }
}
