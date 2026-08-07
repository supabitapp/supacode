import Foundation
import IdentifiedCollections
import Testing

@testable import supacode

struct LayoutsMigratorTests {
  private static func tab(
    id: UUID?,
    title: String = "shell",
    customTitle: String? = nil,
    layout: TerminalLayoutSnapshot.LayoutNode,
    focusedLeafIndex: Int = 0
  ) -> TerminalLayoutSnapshot.TabSnapshot {
    TerminalLayoutSnapshot.TabSnapshot(
      id: id,
      title: title,
      customTitle: customTitle,
      icon: nil,
      tintColor: nil,
      layout: layout,
      focusedLeafIndex: focusedLeafIndex
    )
  }

  private static func leaf(_ id: UUID, workingDirectory: String? = nil)
    -> TerminalLayoutSnapshot.LayoutNode
  {
    .leaf(
      TerminalLayoutSnapshot.SurfaceSnapshot(id: id, workingDirectory: workingDirectory)
    )
  }

  @Test func singleTabMapsToOnePaneKeepingIdentity() throws {
    let tabID = UUID()
    let surfaceID = UUID()
    let snapshot = TerminalLayoutSnapshot(
      tabs: [
        Self.tab(
          id: tabID,
          customTitle: "named",
          layout: Self.leaf(surfaceID, workingDirectory: "/repo")
        )
      ],
      selectedTabIndex: 0
    )
    let record = LayoutsMigrator.migrate(snapshot)
    let layout = record.layout
    #expect(layout.isConsistent)
    #expect(layout.panes.count == 1)
    let pane = try #require(layout.panes.first)
    let tab = try #require(pane.tabs.first)
    #expect(tab.id.rawValue == tabID)
    #expect(tab.customTitle == "named")
    #expect(tab.content.id.rawValue == surfaceID)
    guard case .terminal(let state) = tab.content.state else {
      Issue.record("expected terminal content")
      return
    }
    #expect(state.workingDirectory == "/repo")
    #expect(record.origin == snapshot)
    #expect(layout.tree.zoomed == nil)
  }

  @Test func selectedTabsSplitTreeBecomesThePaneArrangement() throws {
    let tabID = UUID()
    let surfaceA = UUID()
    let surfaceB = UUID()
    let surfaceC = UUID()
    let snapshot = TerminalLayoutSnapshot(
      tabs: [
        Self.tab(
          id: tabID,
          customTitle: "work",
          layout: .split(
            TerminalLayoutSnapshot.SplitSnapshot(
              direction: .horizontal,
              ratio: 0.3,
              left: Self.leaf(surfaceA),
              right: .split(
                TerminalLayoutSnapshot.SplitSnapshot(
                  direction: .vertical,
                  ratio: 0.6,
                  left: Self.leaf(surfaceB),
                  right: Self.leaf(surfaceC)
                )
              )
            )
          ),
          focusedLeafIndex: 1
        )
      ],
      selectedTabIndex: 0
    )
    let layout = LayoutsMigrator.migrate(snapshot).layout
    #expect(layout.isConsistent)
    #expect(layout.panes.count == 3)
    // The tree mirrors directions and ratios over freshly minted pane IDs.
    guard case .split(let rootSplit) = layout.tree.root else {
      Issue.record("expected split root")
      return
    }
    #expect(rootSplit.direction == .horizontal)
    #expect(rootSplit.ratio == 0.3)
    guard case .split(let rightSplit) = rootSplit.right else {
      Issue.record("expected nested split")
      return
    }
    #expect(rightSplit.direction == .vertical)
    #expect(rightSplit.ratio == 0.6)
    // The focused leaf's pane carries the old tab identity and the focus.
    let paneOrder = layout.tree.leaves()
    let focusedPane = try #require(layout.panes[id: paneOrder[1]])
    #expect(focusedPane.tabs.first?.id.rawValue == tabID)
    #expect(focusedPane.tabs.first?.customTitle == "work")
    #expect(layout.focusedPaneID == focusedPane.id)
    // Sibling leaves mint their content UUID as tab ID with no custom title.
    let paneA = try #require(layout.panes[id: paneOrder[0]])
    #expect(paneA.tabs.first?.id.rawValue == surfaceA)
    #expect(paneA.tabs.first?.customTitle == nil)
    #expect(paneA.tabs.first?.title == "shell")
    let paneC = try #require(layout.panes[id: paneOrder[2]])
    #expect(paneC.tabs.first?.id.rawValue == surfaceC)
  }

  @Test func otherTabsLandInTheFocusedPaneInOrder() throws {
    let selectedID = UUID()
    let backgroundID = UUID()
    let fannedID = UUID()
    let surfaceS = UUID()
    let surfaceY = UUID()
    let surfaceT1 = UUID()
    let surfaceT2 = UUID()
    let snapshot = TerminalLayoutSnapshot(
      tabs: [
        Self.tab(id: selectedID, layout: Self.leaf(surfaceS)),
        Self.tab(id: backgroundID, customTitle: "bg", layout: Self.leaf(surfaceY)),
        Self.tab(
          id: fannedID,
          customTitle: "fanned",
          layout: .split(
            TerminalLayoutSnapshot.SplitSnapshot(
              direction: .horizontal,
              ratio: 0.5,
              left: Self.leaf(surfaceT1),
              right: Self.leaf(surfaceT2)
            )
          ),
          focusedLeafIndex: 1
        ),
      ],
      selectedTabIndex: 0
    )
    let layout = LayoutsMigrator.migrate(snapshot).layout
    #expect(layout.isConsistent)
    #expect(layout.panes.count == 1)
    let pane = try #require(layout.panes.first)
    let ids = pane.tabs.map(\.id.rawValue)
    // Selected first (keeps selection), then each tab in order; the fanned
    // tab's leaves stay adjacent with identity on its focused leaf.
    #expect(ids == [selectedID, backgroundID, surfaceT1, fannedID])
    #expect(pane.selectedTabID?.rawValue == selectedID)
    #expect(pane.tabs[id: TerminalTabID(rawValue: backgroundID)]?.customTitle == "bg")
    #expect(pane.tabs[id: TerminalTabID(rawValue: surfaceT1)]?.customTitle == nil)
    #expect(pane.tabs[id: TerminalTabID(rawValue: fannedID)]?.customTitle == "fanned")
    #expect(pane.tabs[id: TerminalTabID(rawValue: fannedID)]?.content.id.rawValue == surfaceT2)
  }

  @Test func everyContentAndTabReferenceSurvivesMigration() throws {
    let tabs: [TerminalLayoutSnapshot.TabSnapshot] = [
      Self.tab(
        id: UUID(),
        layout: .split(
          TerminalLayoutSnapshot.SplitSnapshot(
            direction: .vertical,
            ratio: 0.5,
            left: Self.leaf(UUID()),
            right: Self.leaf(UUID())
          )
        )
      ),
      Self.tab(id: UUID(), layout: Self.leaf(UUID())),
      Self.tab(id: nil, layout: Self.leaf(UUID())),
    ]
    let snapshot = TerminalLayoutSnapshot(tabs: tabs, selectedTabIndex: 1)
    let layout = LayoutsMigrator.migrate(snapshot).layout
    #expect(layout.isConsistent)
    // No content is dropped.
    #expect(Set(layout.allContentIDs.map(\.rawValue)) == Set(snapshot.allSurfaceIDs))
    // Every old tab ID still resolves to a tab.
    for tab in tabs {
      guard let oldID = tab.id else { continue }
      #expect(layout.pane(containingTab: TerminalTabID(rawValue: oldID)) != nil)
    }
    // A legacy tab with no persisted ID adopts its content UUID.
    let legacySurface = tabs[2].layout.firstLeaf.id
    #expect(layout.pane(containingTab: TerminalTabID(rawValue: legacySurface!)) != nil)
  }

  @Test func identityLeafKeepsTheOldTabIDEvenWhenASiblingSharesIt() throws {
    // The normal CLI shape: the tab ID equals the initial leaf's surface UUID,
    // and focus moved to the second leaf. The sibling must not steal the ID.
    let tabID = UUID()
    let secondSurface = UUID()
    let snapshot = TerminalLayoutSnapshot(
      tabs: [
        Self.tab(
          id: tabID,
          customTitle: "mine",
          layout: .split(
            TerminalLayoutSnapshot.SplitSnapshot(
              direction: .horizontal,
              ratio: 0.5,
              left: Self.leaf(tabID),
              right: Self.leaf(secondSurface)
            )
          ),
          focusedLeafIndex: 1
        )
      ],
      selectedTabIndex: 0
    )
    let layout = LayoutsMigrator.migrate(snapshot).layout
    #expect(layout.isConsistent)
    let identityPane = try #require(layout.pane(containingTab: TerminalTabID(rawValue: tabID)))
    let identityTab = try #require(identityPane.tabs[id: TerminalTabID(rawValue: tabID)])
    #expect(identityTab.customTitle == "mine")
    #expect(identityTab.content.id.rawValue == secondSurface)
    // The sibling holding the old tab's surface reminted its tab ID; its
    // content is untouched.
    let sibling = try #require(layout.tab(containingContent: ContentID(rawValue: tabID)))
    #expect(sibling.tab.id.rawValue != tabID)
    #expect(sibling.tab.customTitle == nil)
  }

  @Test func selectedIndexOutOfRangeClampsInsteadOfTrapping() {
    let snapshot = TerminalLayoutSnapshot(
      tabs: [Self.tab(id: UUID(), layout: Self.leaf(UUID()))],
      selectedTabIndex: 7
    )
    let layout = LayoutsMigrator.migrate(snapshot).layout
    #expect(layout.isConsistent)
    #expect(layout.panes.count == 1)
  }

  @Test func emptySnapshotMigratesToAnEmptyRecord() {
    let snapshot = TerminalLayoutSnapshot(tabs: [], selectedTabIndex: 0)
    let record = LayoutsMigrator.migrate(snapshot)
    #expect(record.layout.isConsistent)
    #expect(record.layout.panes.isEmpty)
    #expect(record.origin == snapshot)
  }

  @Test func migratedFileRoundTripsByteStably() throws {
    let snapshot = TerminalLayoutSnapshot(
      tabs: [
        Self.tab(id: UUID(), layout: Self.leaf(UUID())),
        Self.tab(
          id: UUID(),
          layout: .split(
            TerminalLayoutSnapshot.SplitSnapshot(
              direction: .horizontal,
              ratio: 0.4,
              left: Self.leaf(UUID()),
              right: Self.leaf(UUID())
            )
          )
        ),
      ],
      selectedTabIndex: 0
    )
    let file = LayoutsMigrator.migrate(["repo": snapshot])
    #expect(file.schemaVersion == LayoutsFile.currentSchemaVersion)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let first = try encoder.encode(file)
    let decoded = try JSONDecoder().decode(LayoutsFile.self, from: first)
    let second = try encoder.encode(decoded)
    #expect(first == second)
    #expect(decoded == file)
  }

  @Test func rottenWorktreeEntryDropsThatEntryNotTheFile() throws {
    let json = """
      {"schemaVersion":2,"worktrees":{
        "good":{"layout":{"panes":[],"tree":{}}},
        "bad":{"layout":"not an object"}}}
      """
    let decoded = try JSONDecoder().decode(LayoutsFile.self, from: Data(json.utf8))
    #expect(decoded.worktrees.count == 1)
    #expect(decoded.worktrees["good"] != nil)
  }
}
