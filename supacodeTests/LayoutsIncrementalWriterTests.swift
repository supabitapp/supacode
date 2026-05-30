import Dependencies
import Foundation
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
}
