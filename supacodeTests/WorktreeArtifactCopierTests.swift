import Foundation
import Testing

@testable import supacode

struct WorktreeArtifactCopierTests {
  private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test func copiesFilesCreatingIntermediateDirectories() throws {
    let fileManager = FileManager.default
    let source = try makeTempDirectory()
    let destination = try makeTempDirectory()
    defer {
      try? fileManager.removeItem(at: source)
      try? fileManager.removeItem(at: destination)
    }
    try fileManager.createDirectory(
      at: source.appending(path: "config"), withIntermediateDirectories: true)
    try "secret".write(
      to: source.appending(path: "config/app.env"), atomically: true, encoding: .utf8)

    let outcome = WorktreeArtifactCopier.copy(
      relativePaths: ["config/app.env"], from: source, to: destination)

    #expect(outcome.copied == 1)
    #expect(outcome.failed == 0)
    let copied = try String(
      contentsOf: destination.appending(path: "config/app.env"), encoding: .utf8)
    #expect(copied == "secret")
  }

  @Test func preservesSymlinksInsteadOfFollowingThem() throws {
    let fileManager = FileManager.default
    let source = try makeTempDirectory()
    let destination = try makeTempDirectory()
    defer {
      try? fileManager.removeItem(at: source)
      try? fileManager.removeItem(at: destination)
    }
    try "target".write(to: source.appending(path: "real.txt"), atomically: true, encoding: .utf8)
    // A relative symlink target, stored literally (not resolved against CWD).
    try fileManager.createSymbolicLink(
      atPath: source.appending(path: "link.txt").path(percentEncoded: false),
      withDestinationPath: "real.txt")

    let outcome = WorktreeArtifactCopier.copy(
      relativePaths: ["link.txt"], from: source, to: destination)

    #expect(outcome.copied == 1)
    let destinationLink = destination.appending(path: "link.txt")
    let values = try destinationLink.resourceValues(forKeys: [.isSymbolicLinkKey])
    #expect(values.isSymbolicLink == true)
  }

  @Test func copiesASymlinkWhoseTargetIsMissing() throws {
    let fileManager = FileManager.default
    let source = try makeTempDirectory()
    let destination = try makeTempDirectory()
    defer {
      try? fileManager.removeItem(at: source)
      try? fileManager.removeItem(at: destination)
    }
    // A dangling symlink (target absent) must still be copied, like `cp -P`.
    try fileManager.createSymbolicLink(
      atPath: source.appending(path: "link.txt").path(percentEncoded: false),
      withDestinationPath: "gone.txt")

    let outcome = WorktreeArtifactCopier.copy(
      relativePaths: ["link.txt"], from: source, to: destination)

    #expect(outcome.copied == 1)
    let values = try destination.appending(path: "link.txt")
      .resourceValues(forKeys: [.isSymbolicLinkKey])
    #expect(values.isSymbolicLink == true)
  }

  @Test func refusesToCopyThroughASymlinkedDestinationAncestor() throws {
    let fileManager = FileManager.default
    let source = try makeTempDirectory()
    let destination = try makeTempDirectory()
    let external = try makeTempDirectory()
    defer {
      try? fileManager.removeItem(at: source)
      try? fileManager.removeItem(at: destination)
      try? fileManager.removeItem(at: external)
    }
    // Source has cache/file; the destination checks `cache` out as a symlink to
    // an external dir, so a naive copy would write outside the worktree.
    try fileManager.createDirectory(
      at: source.appending(path: "cache"), withIntermediateDirectories: true)
    try "data".write(to: source.appending(path: "cache/file"), atomically: true, encoding: .utf8)
    try fileManager.createSymbolicLink(
      atPath: destination.appending(path: "cache").path(percentEncoded: false),
      withDestinationPath: external.path(percentEncoded: false))

    let outcome = WorktreeArtifactCopier.copy(
      relativePaths: ["cache/file"], from: source, to: destination)

    #expect(outcome.copied == 0)
    #expect(outcome.failed == 1)
    // Nothing was written into the symlink's external target.
    #expect(
      !fileManager.fileExists(atPath: external.appending(path: "file").path(percentEncoded: false)))
  }

  @Test func skipsMissingSourceWithoutCountingFailure() throws {
    let source = try makeTempDirectory()
    let destination = try makeTempDirectory()
    defer {
      try? FileManager.default.removeItem(at: source)
      try? FileManager.default.removeItem(at: destination)
    }

    let outcome = WorktreeArtifactCopier.copy(
      relativePaths: ["gone.env"], from: source, to: destination)

    #expect(outcome.copied == 0)
    #expect(outcome.failed == 0)
  }

  @Test func countsRealCopyFailuresAndKeepsTheFirstError() throws {
    let fileManager = FileManager.default
    let source = try makeTempDirectory()
    let destination = try makeTempDirectory()
    defer {
      try? fileManager.removeItem(at: source)
      try? fileManager.removeItem(at: destination)
    }
    try fileManager.createDirectory(
      at: source.appending(path: "blocked"), withIntermediateDirectories: true)
    try "a".write(to: source.appending(path: "blocked/a"), atomically: true, encoding: .utf8)
    try "b".write(to: source.appending(path: "blocked/b"), atomically: true, encoding: .utf8)
    // A regular file where the destination needs a `blocked/` directory, so the
    // intermediate-directory creation fails for every entry under it (this drives
    // the copy `catch`, not the symlinked-ancestor guard).
    try "x".write(to: destination.appending(path: "blocked"), atomically: true, encoding: .utf8)

    let outcome = WorktreeArtifactCopier.copy(
      relativePaths: ["blocked/a", "blocked/b"], from: source, to: destination)

    #expect(outcome.copied == 0)
    #expect(outcome.failed == 2)
    // The first failure's description is latched and not overwritten by the second.
    #expect(outcome.firstErrorDescription != nil)
  }

  @Test func countsAnUnreadableSourceAsFailedRatherThanSkipping() throws {
    let fileManager = FileManager.default
    let source = try makeTempDirectory()
    let destination = try makeTempDirectory()
    let blockedDir = source.appending(path: "blocked")
    try fileManager.createDirectory(at: blockedDir, withIntermediateDirectories: true)
    try "secret".write(
      to: blockedDir.appending(path: "app.env"), atomically: true, encoding: .utf8)
    // Strip all permission on the parent so the source can't be stat'd: a real
    // failure to surface, not a vanished file to skip silently.
    try fileManager.setAttributes(
      [.posixPermissions: 0], ofItemAtPath: blockedDir.path(percentEncoded: false))
    defer {
      try? fileManager.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: blockedDir.path(percentEncoded: false))
      try? fileManager.removeItem(at: source)
      try? fileManager.removeItem(at: destination)
    }

    let outcome = WorktreeArtifactCopier.copy(
      relativePaths: ["blocked/app.env"], from: source, to: destination)

    #expect(outcome.copied == 0)
    #expect(outcome.failed == 1)
    #expect(outcome.firstErrorDescription != nil)
  }

  @Test func neverClobbersAnExistingDestinationFile() throws {
    let fileManager = FileManager.default
    let source = try makeTempDirectory()
    let destination = try makeTempDirectory()
    defer {
      try? fileManager.removeItem(at: source)
      try? fileManager.removeItem(at: destination)
    }
    try "new".write(to: source.appending(path: "keep.env"), atomically: true, encoding: .utf8)
    try "existing".write(
      to: destination.appending(path: "keep.env"), atomically: true, encoding: .utf8)

    let outcome = WorktreeArtifactCopier.copy(
      relativePaths: ["keep.env"], from: source, to: destination)

    #expect(outcome.copied == 0)
    let preserved = try String(
      contentsOf: destination.appending(path: "keep.env"), encoding: .utf8)
    #expect(preserved == "existing")
  }
}
