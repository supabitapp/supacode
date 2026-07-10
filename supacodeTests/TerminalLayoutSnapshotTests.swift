import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

struct TerminalLayoutSnapshotTests {
  @Test func decodeLegacyTintColorPredefinedString() throws {
    // Old layout snapshots (pre-RepositoryColor cascade) wrote `tintColor`
    // as `TerminalTabTintColor` raw values. The new `RepositoryColor.parse`
    // accepts the same names, so existing files migrate transparently.
    let json = #"""
      {
        "tabs": [
          {
            "id": null,
            "title": "tab",
            "customTitle": null,
            "icon": null,
            "tintColor": "teal",
            "layout": {"leaf": {"_0": {"id": null, "workingDirectory": null}}},
            "focusedLeafIndex": 0
          }
        ],
        "selectedTabIndex": 0
      }
      """#
    let snapshot = try JSONDecoder().decode(TerminalLayoutSnapshot.self, from: Data(json.utf8))
    #expect(snapshot.tabs.first?.tintColor == .teal)
  }

  @Test func decodeLayoutTintColorCustomHex() throws {
    let json = #"""
      {
        "tabs": [
          {
            "id": null,
            "title": "tab",
            "customTitle": null,
            "icon": null,
            "tintColor": "#A1B2C3",
            "layout": {"leaf": {"_0": {"id": null, "workingDirectory": null}}},
            "focusedLeafIndex": 0
          }
        ],
        "selectedTabIndex": 0
      }
      """#
    let snapshot = try JSONDecoder().decode(TerminalLayoutSnapshot.self, from: Data(json.utf8))
    #expect(snapshot.tabs.first?.tintColor == .custom("#A1B2C3"))
  }

  @Test func codableRoundTrip() throws {
    let snapshot = TerminalLayoutSnapshot(
      tabs: [
        TerminalLayoutSnapshot.TabSnapshot(
          id: nil,
          title: "main 1",
          customTitle: nil,
          icon: "terminal",
          tintColor: nil,
          layout: .split(
            TerminalLayoutSnapshot.SplitSnapshot(
              direction: .horizontal,
              ratio: 0.7,
              left: .leaf(
                TerminalLayoutSnapshot.SurfaceSnapshot.terminal(id: nil, workingDirectory: "/Users/test/project")),
              right: .split(
                TerminalLayoutSnapshot.SplitSnapshot(
                  direction: .vertical,
                  ratio: 0.4,
                  left: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot.terminal(id: nil, workingDirectory: "/tmp")),
                  right: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot.terminal(id: nil, workingDirectory: nil))
                )
              )
            )
          ),
          focusedLeafIndex: 1
        ),
        TerminalLayoutSnapshot.TabSnapshot(
          id: nil,
          title: "main 2",
          customTitle: nil,
          icon: nil,
          tintColor: nil,
          layout: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot.terminal(id: nil, workingDirectory: "/Users/test")),
          focusedLeafIndex: 0
        ),
      ],
      selectedTabIndex: 0
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(snapshot)
    let decoded = try JSONDecoder().decode(TerminalLayoutSnapshot.self, from: data)
    #expect(decoded == snapshot)
  }

  @Test func firstLeafReturnsLeftmost() {
    let node: TerminalLayoutSnapshot.LayoutNode = .split(
      TerminalLayoutSnapshot.SplitSnapshot(
        direction: .horizontal,
        ratio: 0.5,
        left: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot.terminal(id: nil, workingDirectory: "/first")),
        right: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot.terminal(id: nil, workingDirectory: "/second"))
      )
    )
    #expect(node.firstLeaf.terminal.workingDirectory == "/first")
  }

  @Test func leafCountCountsAllLeaves() {
    let node: TerminalLayoutSnapshot.LayoutNode = .split(
      TerminalLayoutSnapshot.SplitSnapshot(
        direction: .horizontal,
        ratio: 0.5,
        left: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot.terminal(id: nil, workingDirectory: nil)),
        right: .split(
          TerminalLayoutSnapshot.SplitSnapshot(
            direction: .vertical,
            ratio: 0.5,
            left: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot.terminal(id: nil, workingDirectory: nil)),
            right: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot.terminal(id: nil, workingDirectory: nil))
          )
        )
      )
    )
    #expect(node.leafCount == 3)
  }

  @Test func customTitleRoundTripsInSnapshot() throws {
    let tabSnapshot = TerminalLayoutSnapshot.TabSnapshot(
      id: UUID(),
      title: "supacode 1",
      customTitle: "my-tab",
      icon: nil,
      tintColor: nil,
      layout: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot.terminal(id: UUID(), workingDirectory: nil)),
      focusedLeafIndex: 0
    )
    let snapshot = TerminalLayoutSnapshot(tabs: [tabSnapshot], selectedTabIndex: 0)
    let data = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(TerminalLayoutSnapshot.self, from: data)
    #expect(decoded.tabs.first?.customTitle == "my-tab")
  }

  @Test func missingCustomTitleDecodesAsNil() throws {
    let leaf = #"{"leaf":{"_0":{"workingDirectory":null}}}"#
    let tab = #"{"title":"tab 1","layout":\#(leaf),"focusedLeafIndex":0}"#
    let json = #"{"tabs":[\#(tab)],"selectedTabIndex":0}"#
    let snapshot = try JSONDecoder().decode(
      TerminalLayoutSnapshot.self,
      from: Data(json.utf8)
    )
    #expect(snapshot.tabs.first?.customTitle == nil)
  }

  @Test func singleLeafLayout() throws {
    let snapshot = TerminalLayoutSnapshot(
      tabs: [
        TerminalLayoutSnapshot.TabSnapshot(
          id: nil,
          title: "tab",
          customTitle: nil,
          icon: nil,
          tintColor: nil,
          layout: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot.terminal(id: nil, workingDirectory: "/home")),
          focusedLeafIndex: 0
        )
      ],
      selectedTabIndex: 0
    )

    let data = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(TerminalLayoutSnapshot.self, from: data)
    #expect(decoded.tabs.count == 1)
    #expect(decoded.tabs[0].layout.firstLeaf.terminal.workingDirectory == "/home")
    #expect(decoded.tabs[0].layout.leafCount == 1)
  }

  @Test func allSurfaceIDsCollectsLeavesAcrossTabsAndSplits() {
    let leftSurface = UUID()
    let rightSurface = UUID()
    let secondTabSurface = UUID()
    let snapshot = TerminalLayoutSnapshot(
      tabs: [
        TerminalLayoutSnapshot.TabSnapshot(
          id: UUID(),
          title: "tab1",
          customTitle: nil,
          icon: nil,
          tintColor: nil,
          layout: .split(
            TerminalLayoutSnapshot.SplitSnapshot(
              direction: .horizontal,
              ratio: 0.5,
              left: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot.terminal(id: leftSurface, workingDirectory: nil)),
              right: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot.terminal(id: rightSurface, workingDirectory: nil))
            )
          ),
          focusedLeafIndex: 0
        ),
        TerminalLayoutSnapshot.TabSnapshot(
          id: UUID(),
          title: "tab2",
          customTitle: nil,
          icon: nil,
          tintColor: nil,
          layout: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot.terminal(id: secondTabSurface, workingDirectory: nil)),
          focusedLeafIndex: 0
        ),
      ],
      selectedTabIndex: 0
    )

    #expect(Set(snapshot.allSurfaceIDs) == [leftSurface, rightSurface, secondTabSurface])
  }

  @Test func surfaceSnapshotRoundTripsAgentRecords() throws {
    // Co-locating agent presence with the layout means a Codable round-trip
    // through the on-disk JSON format must preserve every field bit-for-bit;
    // otherwise the relaunch restore would silently miss agents.
    let surfaceID = UUID()
    let snapshot = TerminalLayoutSnapshot(
      tabs: [
        TerminalLayoutSnapshot.TabSnapshot(
          id: UUID(),
          title: "tab",
          customTitle: nil,
          icon: nil,
          tintColor: nil,
          layout: .leaf(
            TerminalLayoutSnapshot.SurfaceSnapshot.terminal(
              id: surfaceID,
              workingDirectory: "/repo",
              agents: [
                TerminalLayoutSnapshot.SurfaceAgentRecord(
                  agent: "claude",
                  pids: [12345, 67890],
                  activity: "busy"
                ),
                TerminalLayoutSnapshot.SurfaceAgentRecord(
                  agent: "codex",
                  pids: [42],
                  activity: "idle"
                ),
              ]
            )
          ),
          focusedLeafIndex: 0
        )
      ],
      selectedTabIndex: 0
    )

    let data = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(TerminalLayoutSnapshot.self, from: data)

    #expect(decoded == snapshot)
    let leaf = decoded.tabs[0].layout.firstLeaf.terminal
    #expect(leaf.agents?.count == 2)
    #expect(leaf.agents?[0].pids == [12345, 67890])
    #expect(leaf.agents?[1].activity == "idle")
  }

  @Test func surfaceSnapshotDecodesWithoutAgentsForBackCompat() throws {
    // Older builds wrote layouts without the `agents` field. Newer builds
    // must decode those without throwing. The synthesized Codable for
    // `LayoutNode` wraps associated values in `_0`.
    let json = """
      {
        "tabs": [
          {
            "id": "00000000-0000-0000-0000-000000000001",
            "title": "tab",
            "layout": {
              "leaf": { "_0": { "id": "00000000-0000-0000-0000-000000000002" } }
            },
            "focusedLeafIndex": 0
          }
        ],
        "selectedTabIndex": 0
      }
      """
    let decoded = try JSONDecoder().decode(
      TerminalLayoutSnapshot.self,
      from: Data(json.utf8)
    )
    let leaf = decoded.tabs[0].layout.firstLeaf.terminal
    #expect(leaf.agents == nil)
    #expect(leaf.id == UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
  }

  @Test func surfaceSnapshotToleratesMalformedAgentsField() throws {
    // A future build with a richer SurfaceAgentRecord shape might serialize a
    // shape this build can't parse. Dropping the field rather than failing
    // the whole layout keeps downgrade scenarios survivable.
    let json = """
      {
        "tabs": [
          {
            "id": "00000000-0000-0000-0000-000000000001",
            "title": "tab",
            "layout": {
              "leaf": {
                "_0": {
                  "id": "00000000-0000-0000-0000-000000000002",
                  "agents": "not-an-array"
                }
              }
            },
            "focusedLeafIndex": 0
          }
        ],
        "selectedTabIndex": 0
      }
      """
    let decoded = try JSONDecoder().decode(
      TerminalLayoutSnapshot.self,
      from: Data(json.utf8)
    )
    let leaf = decoded.tabs[0].layout.firstLeaf.terminal
    #expect(leaf.agents == nil)
  }

  @Test func allAgentRecordsCollectsAcrossTabsAndSplits() {
    let surfaceA = UUID()
    let surfaceB = UUID()
    let layout = TerminalLayoutSnapshot(
      tabs: [
        TerminalLayoutSnapshot.TabSnapshot(
          id: UUID(),
          title: "tab1",
          customTitle: nil,
          icon: nil,
          tintColor: nil,
          layout: .split(
            TerminalLayoutSnapshot.SplitSnapshot(
              direction: .horizontal,
              ratio: 0.5,
              left: .leaf(
                TerminalLayoutSnapshot.SurfaceSnapshot.terminal(
                  id: surfaceA,
                  workingDirectory: nil,
                  agents: [
                    TerminalLayoutSnapshot.SurfaceAgentRecord(
                      agent: "claude", pids: [1], activity: "idle"
                    )
                  ]
                )
              ),
              right: .leaf(
                TerminalLayoutSnapshot.SurfaceSnapshot.terminal(id: surfaceB, workingDirectory: nil, agents: nil)
              )
            )
          ),
          focusedLeafIndex: 0
        )
      ],
      selectedTabIndex: 0
    )

    let records = layout.allAgentRecords()
    #expect(records.count == 1)
    #expect(records[0].surfaceID == surfaceA)
  }

  @Test func allSurfaceIDsSkipsLeavesWithoutIDs() {
    // Snapshots from older builds can carry leaves with `id == nil`; those
    // can't be reaped against (no UUID → no `supa-<uuid>` to match), so they
    // shouldn't appear in the known-set the reaper consults.
    let real = UUID()
    let snapshot = TerminalLayoutSnapshot(
      tabs: [
        TerminalLayoutSnapshot.TabSnapshot(
          id: nil,
          title: "tab",
          customTitle: nil,
          icon: nil,
          tintColor: nil,
          layout: .split(
            TerminalLayoutSnapshot.SplitSnapshot(
              direction: .horizontal,
              ratio: 0.5,
              left: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot.terminal(id: nil, workingDirectory: nil)),
              right: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot.terminal(id: real, workingDirectory: nil))
            )
          ),
          focusedLeafIndex: 0
        )
      ],
      selectedTabIndex: 0
    )

    #expect(snapshot.allSurfaceIDs == [real])
  }
}

extension TerminalLayoutSnapshot.SurfaceSnapshot {
  /// Test convenience: the terminal payload (every leaf in these fixtures is terminal).
  fileprivate var terminal: TerminalLayoutSnapshot.TerminalSurfaceSnapshot {
    switch self {
    case .terminal(let terminal): terminal
    }
  }
}

struct SurfaceSnapshotKindTests {
  /// A leaf kind this build doesn't know (written by a future build) must drop
  /// only the tab containing it; sibling tabs survive.
  @Test func unknownLeafKindDropsOnlyThatTab() throws {
    let json = """
      {
        "tabs": [
          {
            "title": "future",
            "layout": { "leaf": { "_0": { "kind": "browser", "url": "https://example.com" } } },
            "focusedLeafIndex": 0
          },
          {
            "title": "terminal",
            "layout": { "leaf": { "_0": { "id": null, "workingDirectory": "/home" } } },
            "focusedLeafIndex": 0
          }
        ],
        "selectedTabIndex": 0
      }
      """
    let decoded = try JSONDecoder().decode(TerminalLayoutSnapshot.self, from: Data(json.utf8))
    #expect(decoded.tabs.count == 1)
    #expect(decoded.tabs.first?.title == "terminal")
  }

  /// Dropping an unknown-kind tab must remap `selectedTabIndex` into the
  /// surviving array's coordinates, or restore selects the wrong tab.
  @Test func unknownLeafKindBeforeSelectionRemapsSelectedIndex() throws {
    let json = """
      {
        "tabs": [
          {
            "title": "future",
            "layout": { "leaf": { "_0": { "kind": "browser" } } },
            "focusedLeafIndex": 0
          },
          {
            "title": "selected",
            "layout": { "leaf": { "_0": { "id": null, "workingDirectory": null } } },
            "focusedLeafIndex": 0
          },
          {
            "title": "other",
            "layout": { "leaf": { "_0": { "id": null, "workingDirectory": null } } },
            "focusedLeafIndex": 0
          }
        ],
        "selectedTabIndex": 1
      }
      """
    let decoded = try JSONDecoder().decode(TerminalLayoutSnapshot.self, from: Data(json.utf8))
    #expect(decoded.tabs.map(\.title) == ["selected", "other"])
    #expect(decoded.selectedTabIndex == 0)
  }

  /// A dropped tab AFTER the selection must not shift it.
  @Test func unknownLeafKindAfterSelectionKeepsSelectedIndex() throws {
    let json = """
      {
        "tabs": [
          {
            "title": "selected",
            "layout": { "leaf": { "_0": { "id": null, "workingDirectory": null } } },
            "focusedLeafIndex": 0
          },
          {
            "title": "future",
            "layout": { "leaf": { "_0": { "kind": "browser" } } },
            "focusedLeafIndex": 0
          }
        ],
        "selectedTabIndex": 0
      }
      """
    let decoded = try JSONDecoder().decode(TerminalLayoutSnapshot.self, from: Data(json.utf8))
    #expect(decoded.tabs.map(\.title) == ["selected"])
    #expect(decoded.selectedTabIndex == 0)
  }

  /// The terminal case encodes in the legacy flat shape (no `kind` tag) so
  /// layouts written by this build still decode on older builds.
  @Test func terminalLeafEncodesWithoutKindTag() throws {
    let snapshot = TerminalLayoutSnapshot(
      tabs: [
        TerminalLayoutSnapshot.TabSnapshot(
          id: nil,
          title: "tab",
          customTitle: nil,
          icon: nil,
          tintColor: nil,
          layout: .leaf(.terminal(id: nil, workingDirectory: "/home")),
          focusedLeafIndex: 0
        )
      ],
      selectedTabIndex: 0
    )
    let data = try JSONEncoder().encode(snapshot)
    let text = String(bytes: data, encoding: .utf8) ?? ""
    #expect(!text.contains("\"kind\""))
  }
}
