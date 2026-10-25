import Foundation
import Testing

@testable import supacode

struct GitClientTargetStateTests {
  private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test func classifiesAbsentEmptyAndNonEmptyTargets() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(GitClient.targetState(at: root.appending(path: "missing")) == .absent)
    let empty = root.appending(path: "empty")
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    #expect(GitClient.targetState(at: empty) == .emptyDirectory)
    let file = root.appending(path: "file")
    try "x".write(to: file, atomically: true, encoding: .utf8)
    #expect(GitClient.targetState(at: file) == .occupied)
    #expect(GitClient.targetState(at: root) == .occupied)
  }

  @Test func treatsEverySymlinkAsOccupied() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let emptyDirectory = root.appending(path: "empty")
    try FileManager.default.createDirectory(at: emptyDirectory, withIntermediateDirectories: true)
    let linkToEmpty = root.appending(path: "link-to-empty")
    try FileManager.default.createSymbolicLink(at: linkToEmpty, withDestinationURL: emptyDirectory)
    let dangling = root.appending(path: "dangling")
    try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: root.appending(path: "gone"))
    #expect(GitClient.targetState(at: linkToEmpty) == .occupied)
    // Worktree targets carry a directory hint; a trailing slash must not follow the link.
    #expect(GitClient.targetState(at: root.appending(path: "link-to-empty", directoryHint: .isDirectory)) == .occupied)
    #expect(GitClient.targetState(at: root.appending(path: "dangling", directoryHint: .isDirectory)) == .occupied)
    #expect(GitClient.targetState(at: dangling) == .occupied)
    #expect(GitClient.destinationHasContent(at: linkToEmpty))
    #expect(!GitClient.destinationHasContent(at: emptyDirectory))
  }
}
