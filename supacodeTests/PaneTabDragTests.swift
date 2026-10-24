import ComposableArchitecture
import Foundation
import Testing

@testable import supacode

@MainActor
struct PaneTabDragTests {
  /// A one-tab pane beside a two-tab pane.
  private struct Fixture {
    let layout: PaneLayout
    let soloPane: Pane
    let pairPane: Pane
    let soloTabID: TabID
    let pairTabID: TabID
  }

  private func makeTab(_ id: TabID) -> TabItem {
    TabItem(
      id: id,
      title: "Tab",
      content: ContentSnapshot(id: ContentID(), state: .terminal(TerminalContentState(workingDirectory: nil)))
    )
  }

  private func makeFixture() throws -> Fixture {
    let soloTabID = TabID()
    let pairTabID = TabID()
    let otherPairTabID = TabID()
    let soloPane = Pane(id: PaneID(), tabs: [makeTab(soloTabID)], selectedTabID: soloTabID)
    let pairPane = Pane(
      id: PaneID(), tabs: [makeTab(pairTabID), makeTab(otherPairTabID)], selectedTabID: pairTabID)
    let tree = try SplitTree(view: soloPane.id).inserting(view: pairPane.id, at: soloPane.id, direction: .right)
    let layout = PaneLayout(tree: tree, panes: [soloPane, pairPane], focusedPaneID: soloPane.id)
    return Fixture(layout: layout, soloPane: soloPane, pairPane: pairPane, soloTabID: soloTabID, pairTabID: pairTabID)
  }

  @Test func dragStartsCleanAndResetClearsEverySignal() {
    let dragModel = PaneTabDragModel()
    let target = PaneTabDragModel.SpanTarget(anchorPaneID: PaneID(), direction: .right)
    #expect(!dragModel.isDraggingTab)

    dragModel.spanTarget = target
    dragModel.startDrag(from: TabID())
    #expect(dragModel.isDraggingTab)
    #expect(dragModel.spanTarget == nil)

    dragModel.spanTarget = target
    dragModel.reset()
    #expect(!dragModel.isDraggingTab)
    #expect(dragModel.spanTarget == nil)
  }

  @Test func splitDropRefusesOnlyMovesTheLayoutCannotMake() throws {
    let fixture = try makeFixture()
    let layout = fixture.layout

    #expect(PaneTabDrag.canSplitDrop(sourceTabID: nil, anchor: fixture.soloPane, in: layout))
    #expect(!PaneTabDrag.canSplitDrop(sourceTabID: TabID(), anchor: fixture.soloPane, in: layout))
    #expect(!PaneTabDrag.canSplitDrop(sourceTabID: fixture.soloTabID, anchor: fixture.soloPane, in: layout))
    #expect(PaneTabDrag.canSplitDrop(sourceTabID: fixture.soloTabID, anchor: fixture.pairPane, in: layout))
    #expect(PaneTabDrag.canSplitDrop(sourceTabID: fixture.pairTabID, anchor: fixture.pairPane, in: layout))
  }

  @Test func stripDropRefusesTabsFromAnotherLayout() throws {
    let fixture = try makeFixture()

    #expect(PaneTabDrag.canDrop(sourceTabID: nil, in: fixture.layout))
    #expect(PaneTabDrag.canDrop(sourceTabID: fixture.soloTabID, in: fixture.layout))
    #expect(!PaneTabDrag.canDrop(sourceTabID: TabID(), in: fixture.layout))
  }

  // A lingering drag keeps the split zones over the terminal, so even refused drops must end it.
  // An empty payload is refused before the store is read, so this pins the reset-first ordering.
  @Test func refusedDropsStillEndTheTabDrag() throws {
    let fixture = try makeFixture()
    let store = Store(
      initialState: LayoutFeature.State(id: WorktreeID("/tmp/pane-tab-drag"), layout: fixture.layout)
    ) {
      LayoutFeature()
    }
    let pane = fixture.soloPane
    let dragModel = PaneTabDragModel()

    dragModel.startDrag(from: fixture.soloTabID)
    #expect(!PaneTabDrag.performDrop([], into: pane, at: 0, store: store, dragModel: dragModel))
    #expect(!dragModel.isDraggingTab)

    dragModel.startDrag(from: fixture.soloTabID)
    #expect(!PaneTabDrag.performSplitDrop([], anchor: pane, direction: .right, store: store, dragModel: dragModel))
    #expect(!dragModel.isDraggingTab)

    dragModel.startDrag(from: fixture.soloTabID)
    #expect(
      !PaneTabDrag.performSpanningSplitDrop([], anchor: pane, direction: .right, store: store, dragModel: dragModel)
    )
    #expect(!dragModel.isDraggingTab)
  }

  // The main layout renders through the default context, so it must use the model pane windows share.
  @Test func defaultRenderContextUsesTheSharedDragModel() {
    #expect(PaneRenderContext(runtime: ContentRuntime()).dragModel === PaneTabDragModel.shared)
  }
}
