import Dependencies
import Foundation
import IdentifiedCollections
import Sharing
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct LayoutsIncrementalWriterTests {
  private func makeDefaults() -> UserDefaults {
    // A fresh, isolated in-memory store per test so writes never touch disk.
    .inMemory
  }

  private func makeWriter(_ defaults: UserDefaults) -> LayoutsIncrementalWriter {
    LayoutsIncrementalWriter(store: LayoutsUserDefaultsStore(defaults: defaults))
  }

  private func readFile(_ defaults: UserDefaults) -> LayoutsFile? {
    guard let data = defaults.data(forKey: LayoutsFile.userDefaultsKey) else { return nil }
    return try? JSONDecoder().decode(LayoutsFile.self, from: data)
  }

  @Test func identicalReflushKeepsASingleEntry() async {
    let defaults = makeDefaults()
    let writer = makeWriter(defaults)

    let entry = record("/w1")
    await writer.flush(records: ["w1": .record(entry)])
    // Re-splicing the same record changes nothing; the writer skips the write.
    await writer.flush(records: ["w1": .record(entry)])

    #expect(Set(readFile(defaults)?.worktrees.keys.map { $0 } ?? []) == ["w1"])
  }

  @Test func corruptBlobIsStashedAsideThenRecovers() async {
    let defaults = makeDefaults()
    // A wholly-undecodable blob (genuine corruption, or a newer-schema downgrade).
    let garbage = Data("not json".utf8)
    defaults.set(garbage, forKey: LayoutsFile.userDefaultsKey)
    let writer = makeWriter(defaults)

    await writer.flush(records: ["w1": .record(record("/w1"))])

    // The blob is preserved under a sibling key, and the live store recovers to a
    // fresh value rather than wedging forever.
    #expect(defaults.data(forKey: LayoutsFile.userDefaultsKey + ".corrupt") == garbage)
    #expect(readFile(defaults)?.worktrees["w1"] != nil)
  }

  @Test func emptyChangesIsNoOp() async {
    let defaults = makeDefaults()
    let writer = makeWriter(defaults)

    await writer.flush(records: ["w1": .record(record("/w1"))])
    await writer.flush(records: [:])

    #expect(Set(readFile(defaults)?.worktrees.keys.map { $0 } ?? []) == ["w1"])
  }

  // MARK: - v2 record flushes.

  private func record(_ marker: String) -> LayoutRecord {
    let paneID = PaneID()
    let tabID = TabID()
    return LayoutRecord(
      layout: PaneLayout(
        tree: SplitTree(view: paneID),
        panes: [
          Pane(
            id: paneID,
            tabs: [
              TabItem(
                id: tabID,
                title: marker,
                content: ContentSnapshot(
                  id: ContentID(),
                  state: .terminal(TerminalContentState(workingDirectory: marker))
                )
              )
            ],
            selectedTabID: tabID
          )
        ],
        focusedPaneID: paneID
      )
    )
  }

  @Test func recordFlushesStampAndMergeByWorktree() async {
    let defaults = makeDefaults()
    let writer = makeWriter(defaults)

    await writer.flush(records: ["w1": .record(record("/w1"))])
    await writer.flush(records: ["w2": .record(record("/w2"))])

    let file = readFile(defaults)
    #expect(file?.schemaVersion == LayoutsFile.currentSchemaVersion)
    #expect(Set(file?.worktrees.keys.map { $0 } ?? []) == ["w1", "w2"])
  }

  @Test func recordDeleteRemovesOnlyTargetKey() async {
    let defaults = makeDefaults()
    let writer = makeWriter(defaults)

    await writer.flush(records: ["w1": .record(record("/w1")), "w2": .record(record("/w2"))])
    await writer.flush(records: ["w1": .delete])

    #expect(Set(readFile(defaults)?.worktrees.keys.map { $0 } ?? []) == ["w2"])
  }

  @Test func recordFlushPreservesTheWriteOnceOrigin() async {
    let defaults = makeDefaults()
    let writer = makeWriter(defaults)
    let origin = TerminalLayoutSnapshot(tabs: [], selectedTabIndex: 0)

    // First write lands the migration origin; a later live re-save carries none.
    await writer.flush(records: ["w1": .record(LayoutRecord(layout: record("/w1").layout, origin: origin))])
    await writer.flush(records: ["w1": .record(record("/w1b"))])

    #expect(readFile(defaults)?.worktrees["w1"]?.origin != nil)
  }

  @Test func recordFlushSkipsNewerSchema() async {
    let defaults = makeDefaults()
    let newer = LayoutsFile(schemaVersion: LayoutsFile.currentSchemaVersion + 1, worktrees: [:])
    if let data = try? JSONEncoder().encode(newer) {
      defaults.set(data, forKey: LayoutsFile.userDefaultsKey)
    }
    let writer = makeWriter(defaults)

    await writer.flush(records: ["w1": .record(record("/w1"))])

    #expect(readFile(defaults)?.worktrees.isEmpty == true)
  }
}
