import Dependencies
import Foundation
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct NotesIncrementalWriterTests {
  private func note(_ text: String) -> NoteDocument {
    NoteDocument(rtf: Data(text.utf8), lastModified: Date(timeIntervalSince1970: 0))
  }

  private func sub(_ text: String) -> [String: NoteDocument] {
    ["tab1": note(text)]
  }

  private func readDict(_ storage: SettingsFileStorage, _ url: URL) -> [String: [String: NoteDocument]] {
    guard let data = try? storage.load(url) else { return [:] }
    return (try? JSONDecoder().decode([String: [String: NoteDocument]].self, from: data)) ?? [:]
  }

  @Test func separateFlushesBothSurvive() async {
    let storage = SettingsFileStorage.inMemory()
    let url = SupacodePaths.notesURL
    let writer = NotesIncrementalWriter(storage: storage, url: url)

    await writer.flush(["w1": .snapshot(sub("a"))])
    await writer.flush(["w2": .snapshot(sub("b"))])

    #expect(Set(readDict(storage, url).keys) == ["w1", "w2"])
  }

  @Test func deleteRemovesOnlyTargetKey() async {
    let storage = SettingsFileStorage.inMemory()
    let url = SupacodePaths.notesURL
    let writer = NotesIncrementalWriter(storage: storage, url: url)

    await writer.flush(["w1": .snapshot(sub("a")), "w2": .snapshot(sub("b"))])
    await writer.flush(["w1": .delete])

    #expect(Set(readDict(storage, url).keys) == ["w2"])
  }

  @Test func snapshotOverwritesSameKeyButPreservesOthers() async {
    let storage = SettingsFileStorage.inMemory()
    let url = SupacodePaths.notesURL
    let writer = NotesIncrementalWriter(storage: storage, url: url)

    await writer.flush(["w1": .snapshot(sub("old")), "w2": .snapshot(sub("b"))])
    await writer.flush(["w1": .snapshot(sub("new"))])

    let dict = readDict(storage, url)
    #expect(dict["w2"] != nil)
    #expect(dict["w1"]?["tab1"]?.rtf == Data("new".utf8))
  }

  @Test func identicalReflushSkipsTheWrite() async {
    let inner = SettingsFileStorage.inMemory()
    let url = SupacodePaths.notesURL
    let saveCount = LockIsolated(0)
    let storage = SettingsFileStorage(
      load: { try inner.load($0) },
      save: { data, target in
        if target == url { saveCount.withValue { $0 += 1 } }
        try inner.save(data, target)
      }
    )
    let writer = NotesIncrementalWriter(storage: storage, url: url)

    await writer.flush(["w1": .snapshot(sub("a"))])
    await writer.flush(["w1": .snapshot(sub("a"))])

    #expect(saveCount.value == 1)
  }

  @Test func corruptFileIsRotatedAsideAndPersistenceRecovers() async throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "NotesWriterCorrupt-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appending(path: "notes.json", directoryHint: .notDirectory)
    try Data("not json".utf8).write(to: url)

    let storage = SettingsFileStorage(
      load: { try Data(contentsOf: $0) },
      save: { data, target in try data.write(to: target, options: .atomic) }
    )
    let writer = NotesIncrementalWriter(storage: storage, url: url)
    await writer.flush(["w1": .snapshot(sub("a"))])

    #expect(readDict(storage, url)["w1"] != nil)
    let rotated = try FileManager.default
      .contentsOfDirectory(atPath: dir.path(percentEncoded: false))
      .filter { $0.hasPrefix("notes.json.corrupt-") }
    #expect(rotated.count == 1)
  }

  @Test func emptyChangesIsNoOp() async {
    let storage = SettingsFileStorage.inMemory()
    let url = SupacodePaths.notesURL
    let writer = NotesIncrementalWriter(storage: storage, url: url)

    await writer.flush(["w1": .snapshot(sub("a"))])
    await writer.flush([:])

    #expect(Set(readDict(storage, url).keys) == ["w1"])
  }
}
