import Dependencies
import Foundation
import IdentifiedCollections
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct LayoutsIncrementalWriterTests {
  private func snapshot(dir: String) -> TerminalLayoutSnapshot {
    TerminalLayoutSnapshot(
      tabs: [
        TerminalLayoutSnapshot.TabSnapshot(
          id: nil,
          title: "Terminal 1",
          customTitle: nil,
          icon: nil,
          tintColor: nil,
          layout: .leaf(
            TerminalLayoutSnapshot.SurfaceSnapshot(id: nil, workingDirectory: dir)
          ),
          focusedLeafIndex: 0
        )
      ],
      selectedTabIndex: 0
    )
  }

  private func readDict(_ storage: SettingsFileStorage, _ url: URL) -> [String: TerminalLayoutSnapshot] {
    guard let data = try? storage.load(url) else { return [:] }
    return (try? JSONDecoder().decode([String: TerminalLayoutSnapshot].self, from: data)) ?? [:]
  }

  @Test func separateFlushesBothSurvive() async {
    let storage = SettingsFileStorage.inMemory()
    let url = SupacodePaths.layoutsURL
    let writer = LayoutsIncrementalWriter(storage: storage, url: url)

    await writer.flush(["w1": .snapshot(snapshot(dir: "/w1"))])
    await writer.flush(["w2": .snapshot(snapshot(dir: "/w2"))])

    let dict = readDict(storage, url)
    #expect(Set(dict.keys) == ["w1", "w2"])
  }

  @Test func deleteRemovesOnlyTargetKey() async {
    let storage = SettingsFileStorage.inMemory()
    let url = SupacodePaths.layoutsURL
    let writer = LayoutsIncrementalWriter(storage: storage, url: url)

    await writer.flush([
      "w1": .snapshot(snapshot(dir: "/w1")),
      "w2": .snapshot(snapshot(dir: "/w2")),
    ])
    await writer.flush(["w1": .delete])

    let dict = readDict(storage, url)
    #expect(Set(dict.keys) == ["w2"])
  }

  @Test func snapshotOverwritesSameKeyButPreservesOthers() async {
    let storage = SettingsFileStorage.inMemory()
    let url = SupacodePaths.layoutsURL
    let writer = LayoutsIncrementalWriter(storage: storage, url: url)

    await writer.flush([
      "w1": .snapshot(snapshot(dir: "/old")),
      "w2": .snapshot(snapshot(dir: "/w2")),
    ])
    await writer.flush(["w1": .snapshot(snapshot(dir: "/new"))])

    let dict = readDict(storage, url)
    #expect(dict["w2"] != nil)
    let leaf = dict["w1"]?.tabs.first?.layout
    if case .leaf(let surface) = leaf {
      #expect(surface.workingDirectory == "/new")
    } else {
      Issue.record("Expected a leaf layout for w1")
    }
  }

  @Test func identicalReflushSkipsTheWrite() async {
    let inner = SettingsFileStorage.inMemory()
    let url = SupacodePaths.layoutsURL
    let saveCount = LockIsolated(0)
    let storage = SettingsFileStorage(
      load: { try inner.load($0) },
      save: { data, target in
        if target == url { saveCount.withValue { $0 += 1 } }
        try inner.save(data, target)
      }
    )
    let writer = LayoutsIncrementalWriter(storage: storage, url: url)

    await writer.flush(["w1": .snapshot(snapshot(dir: "/w1"))])
    // Re-splicing the same snapshot is a no-op; the second flush must not write.
    await writer.flush(["w1": .snapshot(snapshot(dir: "/w1"))])

    #expect(saveCount.value == 1)
    #expect(Set(readDict(storage, url).keys) == ["w1"])
  }

  @Test func corruptFileIsRotatedAsideAndPersistenceRecovers() async throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "LayoutsWriterCorrupt-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appending(path: "layouts.json", directoryHint: .notDirectory)
    // Seed garbage so the decode fails on the next merge read.
    try Data("not json".utf8).write(to: url)

    let storage = SettingsFileStorage(
      load: { try Data(contentsOf: $0) },
      save: { data, target in try data.write(to: target, options: .atomic) }
    )
    let writer = LayoutsIncrementalWriter(storage: storage, url: url)
    await writer.flush(["w1": .snapshot(snapshot(dir: "/w1"))])

    // Self-healed: the new key persisted instead of the flush aborting forever.
    #expect(readDict(storage, url)["w1"] != nil)
    // The corrupt bytes were preserved under a rotated name, not overwritten.
    let rotated = try FileManager.default
      .contentsOfDirectory(atPath: dir.path(percentEncoded: false))
      .filter { $0.hasPrefix("layouts.json.corrupt-") }
    #expect(rotated.count == 1)
  }

  @Test func emptyChangesIsNoOp() async {
    let storage = SettingsFileStorage.inMemory()
    let url = SupacodePaths.layoutsURL
    let writer = LayoutsIncrementalWriter(storage: storage, url: url)

    await writer.flush(["w1": .snapshot(snapshot(dir: "/w1"))])
    await writer.flush([:])

    #expect(Set(readDict(storage, url).keys) == ["w1"])
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

  private func readFile(_ storage: SettingsFileStorage, _ url: URL) -> LayoutsFile? {
    guard let data = try? storage.load(url) else { return nil }
    return try? JSONDecoder().decode(LayoutsFile.self, from: data)
  }

  @Test func recordFlushesStampAndMergeByWorktree() async {
    let storage = SettingsFileStorage.inMemory()
    let url = SupacodePaths.layoutsURL
    let writer = LayoutsIncrementalWriter(storage: storage, url: url)

    await writer.flush(records: ["w1": .record(record("/w1"))])
    await writer.flush(records: ["w2": .record(record("/w2"))])

    let file = readFile(storage, url)
    #expect(file?.schemaVersion == LayoutsFile.currentSchemaVersion)
    #expect(Set(file?.worktrees.keys.map { $0 } ?? []) == ["w1", "w2"])
  }

  @Test func recordDeleteRemovesOnlyTargetKey() async {
    let storage = SettingsFileStorage.inMemory()
    let url = SupacodePaths.layoutsURL
    let writer = LayoutsIncrementalWriter(storage: storage, url: url)

    await writer.flush(records: ["w1": .record(record("/w1")), "w2": .record(record("/w2"))])
    await writer.flush(records: ["w1": .delete])

    #expect(Set(readFile(storage, url)?.worktrees.keys.map { $0 } ?? []) == ["w2"])
  }

  @Test func recordFlushPreservesTheWriteOnceOrigin() async {
    let storage = SettingsFileStorage.inMemory()
    let url = SupacodePaths.layoutsURL
    let writer = LayoutsIncrementalWriter(storage: storage, url: url)
    let origin = TerminalLayoutSnapshot(tabs: [], selectedTabIndex: 0)

    // First write lands the migration origin; a later live re-save carries none.
    await writer.flush(records: ["w1": .record(LayoutRecord(layout: record("/w1").layout, origin: origin))])
    await writer.flush(records: ["w1": .record(record("/w1b"))])

    #expect(readFile(storage, url)?.worktrees["w1"]?.origin != nil)
  }

  @Test func recordFlushWillNotWriteIntoStillV1Bytes() async {
    let storage = SettingsFileStorage.inMemory()
    let url = SupacodePaths.layoutsURL
    // A deferred migration left a v1 file in place.
    let legacy = ["w1": snapshot(dir: "/w1")]
    try? storage.save(JSONEncoder().encode(legacy), url)
    let writer = LayoutsIncrementalWriter(storage: storage, url: url)

    await writer.flush(records: ["w2": .record(record("/w2"))])

    // The v1 bytes must survive untouched for the next launch's migrator.
    #expect(readFile(storage, url) == nil)
    #expect(readDict(storage, url)["w1"] != nil)
  }

  @Test func recordFlushSkipsNewerSchema() async {
    let storage = SettingsFileStorage.inMemory()
    let url = SupacodePaths.layoutsURL
    let newer = LayoutsFile(schemaVersion: LayoutsFile.currentSchemaVersion + 1, worktrees: [:])
    try? storage.save(JSONEncoder().encode(newer), url)
    let writer = LayoutsIncrementalWriter(storage: storage, url: url)

    await writer.flush(records: ["w1": .record(record("/w1"))])

    #expect(readFile(storage, url)?.worktrees.isEmpty == true)
  }
}
