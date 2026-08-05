import Foundation
import Testing

@testable import supacode

struct FileExplorerClientTests {
  private let fileManager = FileManager.default

  private func makeTempDir() throws -> URL {
    let dir = fileManager.temporaryDirectory
      .appending(path: "file-explorer-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func touch(_ name: String, in dir: URL) throws {
    try Data().write(to: dir.appending(path: name, directoryHint: .notDirectory))
  }

  private func makeDir(_ name: String, in dir: URL) throws {
    try fileManager.createDirectory(
      at: dir.appending(path: name, directoryHint: .isDirectory),
      withIntermediateDirectories: true
    )
  }

  @Test func sortsDirectoriesFirstThenFinderLike() throws {
    let dir = try makeTempDir()
    defer { try? fileManager.removeItem(at: dir) }
    try touch("zebra.swift", in: dir)
    try touch("Apple.swift", in: dir)
    try touch("file10.txt", in: dir)
    try touch("file2.txt", in: dir)
    try makeDir("src", in: dir)
    try makeDir("Beta", in: dir)

    let listing = try FileExplorerClient.listDirectory(at: dir, limit: .max)

    #expect(listing.entries.map(\.name) == ["Beta", "src", "Apple.swift", "file2.txt", "file10.txt", "zebra.swift"])
    #expect(listing.totalCount == 6)
    #expect(!listing.isTruncated)
    // The sweep's staleness gate needs a baseline; a nil date would either
    // disable or endlessly churn the sweep.
    #expect(listing.modificationDate != nil)
  }

  @Test func includesDotfilesAndExcludesGitDirectory() throws {
    let dir = try makeTempDir()
    defer { try? fileManager.removeItem(at: dir) }
    try touch(".env", in: dir)
    try makeDir(".github", in: dir)
    try makeDir(".git", in: dir)
    try touch("a.txt", in: dir)

    let listing = try FileExplorerClient.listDirectory(at: dir, limit: .max)

    #expect(listing.entries.map(\.name) == [".github", ".env", "a.txt"])
  }

  @Test func capsEntriesAndReportsTotalCount() throws {
    let dir = try makeTempDir()
    defer { try? fileManager.removeItem(at: dir) }
    for index in 0..<20 {
      try touch("file-\(index).txt", in: dir)
    }

    let listing = try FileExplorerClient.listDirectory(at: dir, limit: 5)

    // The cap keeps the first entries in sorted order, not read order.
    #expect(
      listing.entries.map(\.name) == ["file-0.txt", "file-1.txt", "file-2.txt", "file-3.txt", "file-4.txt"]
    )
    #expect(listing.totalCount == 20)
    #expect(listing.isTruncated)
  }

  @Test func listingExactlyAtTheCapIsNotTruncated() throws {
    let dir = try makeTempDir()
    defer { try? fileManager.removeItem(at: dir) }
    for index in 0..<5 {
      try touch("file-\(index).txt", in: dir)
    }

    let listing = try FileExplorerClient.listDirectory(at: dir, limit: 5)

    #expect(listing.entries.count == 5)
    #expect(listing.totalCount == 5)
    #expect(!listing.isTruncated)
  }

  @Test func negativeLimitYieldsEmptyTruncatedListing() throws {
    let dir = try makeTempDir()
    defer { try? fileManager.removeItem(at: dir) }
    try touch("a.txt", in: dir)

    let listing = try FileExplorerClient.listDirectory(at: dir, limit: -1)

    #expect(listing.entries.isEmpty)
    #expect(listing.totalCount == 1)
  }

  @Test func flagsSymlinksAndResolvesDirectoryTargets() throws {
    let dir = try makeTempDir()
    defer { try? fileManager.removeItem(at: dir) }
    try makeDir("target-dir", in: dir)
    try touch("target-file.txt", in: dir)
    try fileManager.createSymbolicLink(
      at: dir.appending(path: "dir-link", directoryHint: .notDirectory),
      withDestinationURL: dir.appending(path: "target-dir", directoryHint: .isDirectory)
    )
    try fileManager.createSymbolicLink(
      at: dir.appending(path: "file-link", directoryHint: .notDirectory),
      withDestinationURL: dir.appending(path: "target-file.txt", directoryHint: .notDirectory)
    )
    try fileManager.createSymbolicLink(
      at: dir.appending(path: "broken-link", directoryHint: .notDirectory),
      withDestinationURL: dir.appending(path: "missing", directoryHint: .notDirectory)
    )

    let listing = try FileExplorerClient.listDirectory(at: dir, limit: .max)
    let byName = Dictionary(uniqueKeysWithValues: listing.entries.map { ($0.name, $0) })

    #expect(byName["dir-link"]?.isDirectory == true)
    #expect(byName["dir-link"]?.isSymbolicLink == true)
    #expect(byName["file-link"]?.isDirectory == false)
    #expect(byName["file-link"]?.isSymbolicLink == true)
    #expect(byName["broken-link"]?.isDirectory == false)
    #expect(byName["target-dir"]?.isSymbolicLink == false)
  }

  @Test func survivesHostileFilenames() throws {
    let dir = try makeTempDir()
    defer { try? fileManager.removeItem(at: dir) }
    try touch("emoji-🚀.txt", in: dir)
    try touch("with space.txt", in: dir)
    try touch("new\nline.txt", in: dir)

    let listing = try FileExplorerClient.listDirectory(at: dir, limit: .max)

    #expect(listing.entries.count == 3)
    #expect(listing.entries.contains { $0.name == "new\nline.txt" })
    #expect(listing.entries.contains { $0.name == "emoji-🚀.txt" })
    #expect(listing.entries.contains { $0.name == "with space.txt" })
  }

  @Test func missingDirectoryThrowsNotFound() throws {
    let dir = try makeTempDir()
    defer { try? fileManager.removeItem(at: dir) }
    let missing = dir.appending(path: "missing", directoryHint: .isDirectory)

    #expect(throws: FileExplorerListingError.notFound) {
      try FileExplorerClient.listDirectory(at: missing, limit: .max)
    }
  }

  @Test func unreadableDirectoryThrowsPermissionDenied() throws {
    let dir = try makeTempDir()
    defer { try? fileManager.removeItem(at: dir) }
    let locked = dir.appending(path: "locked", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: locked, withIntermediateDirectories: true)
    try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path(percentEncoded: false))
    defer {
      try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path(percentEncoded: false))
    }

    #expect(throws: FileExplorerListingError.permissionDenied) {
      try FileExplorerClient.listDirectory(at: locked, limit: .max)
    }
  }

  @Test func modificationDatesSkipUnstattableDirectories() throws {
    let dir = try makeTempDir()
    defer { try? fileManager.removeItem(at: dir) }
    try makeDir("real", in: dir)
    let real = dir.appending(path: "real", directoryHint: .isDirectory)
    let missing = dir.appending(path: "missing", directoryHint: .isDirectory)

    let dates = FileExplorerClient.contentModificationDates(of: [real, missing])

    #expect(dates[real] != nil)
    #expect(dates[missing] == nil)
  }

  @Test func modificationDatesBypassTheURLResourceCache() throws {
    let dir = try makeTempDir()
    defer { try? fileManager.removeItem(at: dir) }
    // Deliberately reuse the SAME URL instance for both reads: URLs memoize
    // resource values, and the sweep must observe fresh mtimes anyway.
    let before = try #require(FileExplorerClient.contentModificationDates(of: [dir])[dir])
    try fileManager.setAttributes(
      [.modificationDate: before.addingTimeInterval(2)],
      ofItemAtPath: dir.path(percentEncoded: false)
    )

    let after = try #require(FileExplorerClient.contentModificationDates(of: [dir])[dir])

    #expect(after > before)
  }

  @Test func listsALargeDirectoryWithinBudget() throws {
    let dir = try makeTempDir()
    defer { try? fileManager.removeItem(at: dir) }
    for index in 0..<10_000 {
      try touch("file-\(index).txt", in: dir)
    }
    try makeDir("directory", in: dir)

    let start = ContinuousClock.now
    let listing = try FileExplorerClient.listDirectory(at: dir, limit: 1_000)
    let elapsed = ContinuousClock.now - start

    #expect(listing.entries.first?.name == "directory")
    #expect(listing.entries.count == 1_000)
    #expect(listing.totalCount == 10_001)
    // Generous bound: catches accidental quadratic behavior, not CI jitter.
    #expect(elapsed < .seconds(10))
  }
}
