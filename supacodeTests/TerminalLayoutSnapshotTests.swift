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
              left: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot(id: nil, workingDirectory: "/Users/test/project")),
              right: .split(
                TerminalLayoutSnapshot.SplitSnapshot(
                  direction: .vertical,
                  ratio: 0.4,
                  left: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot(id: nil, workingDirectory: "/tmp")),
                  right: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot(id: nil, workingDirectory: nil))
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
          layout: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot(id: nil, workingDirectory: "/Users/test")),
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
        left: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot(id: nil, workingDirectory: "/first")),
        right: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot(id: nil, workingDirectory: "/second"))
      )
    )
    #expect(node.firstLeaf.workingDirectory == "/first")
  }

  @Test func leafCountCountsAllLeaves() {
    let node: TerminalLayoutSnapshot.LayoutNode = .split(
      TerminalLayoutSnapshot.SplitSnapshot(
        direction: .horizontal,
        ratio: 0.5,
        left: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot(id: nil, workingDirectory: nil)),
        right: .split(
          TerminalLayoutSnapshot.SplitSnapshot(
            direction: .vertical,
            ratio: 0.5,
            left: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot(id: nil, workingDirectory: nil)),
            right: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot(id: nil, workingDirectory: nil))
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
      layout: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot(id: UUID(), workingDirectory: nil)),
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

  @Test func restorableAgentRoundTrips() throws {
    let snapshot = TerminalLayoutSnapshot(
      tabs: [
        TerminalLayoutSnapshot.TabSnapshot(
          id: nil,
          title: "tab",
          customTitle: nil,
          icon: nil,
          tintColor: nil,
          layout: .leaf(
            TerminalLayoutSnapshot.SurfaceSnapshot(
              id: nil,
              workingDirectory: "/tmp",
              restorableAgent: TerminalLayoutSnapshot.RestorableAgent(
                agent: .claude,
                sessionID: "abc-123"
              )
            )
          ),
          focusedLeafIndex: 0
        )
      ],
      selectedTabIndex: 0
    )
    let data = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(TerminalLayoutSnapshot.self, from: data)
    #expect(decoded.tabs.first?.layout.firstLeaf.restorableAgent?.agent == .claude)
    #expect(decoded.tabs.first?.layout.firstLeaf.restorableAgent?.sessionID == "abc-123")
  }

  @Test func restorableAgentMissingDecodesAsNil() throws {
    // Forward-compat: older snapshots without the field load cleanly.
    let json = #"""
      {
        "tabs": [
          {
            "id": null,
            "title": "tab",
            "customTitle": null,
            "icon": null,
            "tintColor": null,
            "layout": {"leaf": {"_0": {"id": null, "workingDirectory": "/tmp"}}},
            "focusedLeafIndex": 0
          }
        ],
        "selectedTabIndex": 0
      }
      """#
    let snapshot = try JSONDecoder().decode(TerminalLayoutSnapshot.self, from: Data(json.utf8))
    #expect(snapshot.tabs.first?.layout.firstLeaf.restorableAgent == nil)
  }

  @Test func restorableAgentUnknownAgentIsDroppedNotRejected() throws {
    // Lossy: an agent rawValue the running build doesn't recognize (e.g. a
    // new agent type shipped by a newer build) must not fail the whole leaf
    // decode — restorableAgent drops to nil, the surface stays intact.
    let json = #"""
      {
        "tabs": [
          {
            "id": null,
            "title": "tab",
            "customTitle": null,
            "icon": null,
            "tintColor": null,
            "layout": {
              "leaf": {
                "_0": {
                  "id": null,
                  "workingDirectory": "/tmp",
                  "restorableAgent": {"agent": "futuristic", "sessionID": "x"}
                }
              }
            },
            "focusedLeafIndex": 0
          }
        ],
        "selectedTabIndex": 0
      }
      """#
    let snapshot = try JSONDecoder().decode(TerminalLayoutSnapshot.self, from: Data(json.utf8))
    #expect(snapshot.tabs.first?.layout.firstLeaf.workingDirectory == "/tmp")
    #expect(snapshot.tabs.first?.layout.firstLeaf.restorableAgent == nil)
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
          layout: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot(id: nil, workingDirectory: "/home")),
          focusedLeafIndex: 0
        )
      ],
      selectedTabIndex: 0
    )

    let data = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(TerminalLayoutSnapshot.self, from: data)
    #expect(decoded.tabs.count == 1)
    #expect(decoded.tabs[0].layout.firstLeaf.workingDirectory == "/home")
    #expect(decoded.tabs[0].layout.leafCount == 1)
  }
}
