import Foundation
import IdentifiedCollections
import Testing

@testable import supacode

struct PaneLayoutTests {
  private static func terminalTab(
    id: UUID,
    title: String = "shell",
    workingDirectory: String? = nil
  ) -> TabItem {
    TabItem(
      id: TabID(rawValue: id),
      title: title,
      content: ContentSnapshot(
        id: ContentID(rawValue: id),
        state: .terminal(TerminalContentState(workingDirectory: workingDirectory))
      )
    )
  }

  @Test func roundTripsASplitLayoutWithFocusAndSelection() throws {
    let paneA = PaneID()
    let paneB = PaneID()
    let tabOne = Self.terminalTab(id: UUID(), workingDirectory: "/tmp/a")
    let tabTwo = Self.terminalTab(id: UUID())
    let tabThree = Self.terminalTab(id: UUID())
    let layout = PaneLayout(
      tree: try SplitTree(view: paneA).inserting(view: paneB, at: paneA, direction: .right, ratio: 0.3),
      panes: [
        Pane(id: paneA, tabs: [tabOne, tabTwo], selectedTabID: tabTwo.id),
        Pane(id: paneB, tabs: [tabThree], selectedTabID: tabThree.id),
      ],
      focusedPaneID: paneB
    )
    #expect(layout.isConsistent)
    let data = try JSONEncoder().encode(layout)
    let decoded = try JSONDecoder().decode(PaneLayout.self, from: data)
    #expect(decoded == layout)
    #expect(decoded.isConsistent)
  }

  @Test func wireFormatIsPinned() throws {
    let paneID = PaneID(rawValue: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!)
    let tabID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!
    let layout = PaneLayout(
      tree: SplitTree(view: paneID),
      panes: [
        Pane(
          id: paneID,
          tabs: [Self.terminalTab(id: tabID, title: "agent", workingDirectory: "/repo")],
          selectedTabID: TabID(rawValue: tabID)
        )
      ],
      focusedPaneID: paneID
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let json = try #require(String(bytes: encoder.encode(layout), encoding: .utf8))
    let expected = """
      {"focusedPaneID":"AAAAAAAA-0000-0000-0000-000000000001",\
      "panes":[{"id":"AAAAAAAA-0000-0000-0000-000000000001",\
      "selectedTabID":"BBBBBBBB-0000-0000-0000-000000000002",\
      "tabs":[{"content":{"id":"BBBBBBBB-0000-0000-0000-000000000002",\
      "state":{"kind":"terminal","terminal":{"workingDirectory":"\\/repo"}}},\
      "id":"BBBBBBBB-0000-0000-0000-000000000002","title":"agent"}]}],\
      "tree":{"root":{"kind":"leaf","leaf":"AAAAAAAA-0000-0000-0000-000000000001"}}}
      """
    #expect(json == expected)
  }

  @Test func decodeRepairsDanglingSelectionAndFocus() throws {
    let paneID = PaneID()
    let tab = Self.terminalTab(id: UUID())
    var layout = PaneLayout(
      tree: SplitTree(view: paneID),
      panes: [Pane(id: paneID, tabs: [tab], selectedTabID: tab.id)],
      focusedPaneID: paneID
    )
    // Corrupt selection and focus to IDs that do not resolve.
    layout.panes[id: paneID]?.selectedTabID = TabID()
    layout.focusedPaneID = nil
    let data = try JSONEncoder().encode(layout)
    let decoded = try JSONDecoder().decode(PaneLayout.self, from: data)
    #expect(decoded.panes[id: paneID]?.selectedTabID == tab.id)
    #expect(decoded.focusedPaneID == paneID)
  }

  @Test func inconsistencyIsDetected() throws {
    let paneA = PaneID()
    let orphanPane = Pane(id: PaneID(), tabs: [Self.terminalTab(id: UUID())])
    let layout = PaneLayout(
      tree: SplitTree(view: paneA),
      panes: [Pane(id: paneA, tabs: [Self.terminalTab(id: UUID())]), orphanPane]
    )
    // The orphan pane has no tree leaf.
    #expect(!layout.isConsistent)
  }

  @Test func emptyPanesAndDroppedFocusAreInconsistent() {
    let paneA = PaneID()
    var layout = PaneLayout(
      tree: SplitTree(view: paneA),
      panes: [Pane(id: paneA, tabs: [Self.terminalTab(id: UUID())])]
    )
    #expect(layout.isConsistent)
    layout.focusedPaneID = nil
    #expect(!layout.isConsistent)
    layout = PaneLayout(
      tree: SplitTree(view: paneA),
      panes: [Pane(id: paneA)]
    )
    #expect(!layout.isConsistent)
  }

  @Test func decodeKeepsFirstDuplicateTabAndDropsUnknownContentKind() throws {
    // Literal JSON: same tab ID twice plus a content kind this build does not
    // know; decode must keep the first duplicate and drop only the alien tab.
    let json = """
      {"focusedPaneID":"AAAAAAAA-0000-0000-0000-000000000001",
       "panes":[{"id":"AAAAAAAA-0000-0000-0000-000000000001",
        "tabs":[
         {"content":{"id":"BBBBBBBB-0000-0000-0000-000000000002",
          "state":{"kind":"terminal","terminal":{}}},
          "id":"BBBBBBBB-0000-0000-0000-000000000002","title":"first"},
         {"content":{"id":"BBBBBBBB-0000-0000-0000-000000000002",
          "state":{"kind":"terminal","terminal":{}}},
          "id":"BBBBBBBB-0000-0000-0000-000000000002","title":"duplicate"},
         {"content":{"id":"CCCCCCCC-0000-0000-0000-000000000003",
          "state":{"kind":"hologram","hologram":{}}},
          "id":"CCCCCCCC-0000-0000-0000-000000000003","title":"alien"}
        ]}],
       "tree":{"root":{"kind":"leaf","leaf":"AAAAAAAA-0000-0000-0000-000000000001"}}}
      """
    let decoded = try JSONDecoder().decode(PaneLayout.self, from: Data(json.utf8))
    let pane = try #require(decoded.panes.first)
    #expect(pane.tabs.count == 1)
    #expect(pane.tabs.first?.title == "first")
    #expect(decoded.isConsistent)
  }

  @Test func lookupsResolveTabAndContentOwnership() {
    let paneA = PaneID()
    let contentID = UUID()
    let tab = Self.terminalTab(id: contentID)
    let layout = PaneLayout(
      tree: SplitTree(view: paneA),
      panes: [Pane(id: paneA, tabs: [tab], selectedTabID: tab.id)],
      focusedPaneID: paneA
    )
    #expect(layout.pane(containingTab: tab.id)?.id == paneA)
    #expect(layout.tab(containingContent: ContentID(rawValue: contentID))?.tab.id == tab.id)
    #expect(layout.allContentIDs == [ContentID(rawValue: contentID)])
  }
}
