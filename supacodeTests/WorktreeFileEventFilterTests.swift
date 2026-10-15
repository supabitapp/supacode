import CoreServices
import Foundation
import Testing

@testable import supacode

struct WorktreeFileEventFilterTests {
  @Test(arguments: [
    "fsmonitor--daemon",
    "fsmonitor--daemon/cookies",
    "fsmonitor--daemon/cookies/1234-1",
    "fsmonitor--daemon.ipc",
    "fsmonitor--daemon.ipc.lock",
    "worktrees/feature/fsmonitor--daemon/cookies/1234-1",
    "worktrees/feature/fsmonitor--daemon.ipc",
  ])
  func ignoresDaemonActivityInsideGitDirectory(relativePath: String) {
    let filter = WorktreeFileEventFilter(gitDirectoryURL: URL(fileURLWithPath: "/repo/.git"))
    #expect(!filter.shouldRefresh(paths: ["/repo/.git/" + relativePath], flags: [0]))
  }

  @Test(arguments: [
    "/repo/.git/worktrees/feature",
    "/repo/.bare/worktrees/feature",
    "/separate-metadata",
  ])
  func ignoresDaemonActivityInResolvedGitDirectories(gitDirectoryPath: String) {
    let filter = WorktreeFileEventFilter(gitDirectoryURL: URL(fileURLWithPath: gitDirectoryPath))
    #expect(
      !filter.shouldRefresh(
        paths: [gitDirectoryPath + "/fsmonitor--daemon/cookies/1234-1"], flags: [0]))
    #expect(filter.shouldRefresh(paths: [gitDirectoryPath + "/index"], flags: [0]))
  }

  @Test(arguments: [
    "/repo/Sources/main.swift",
    "/repo/fsmonitor--daemon/source.swift",
    "/repo/fsmonitor--daemon.ipc",
    "/repo/.github/fsmonitor--daemon/source.swift",
    "/repo/.git-backup/fsmonitor--daemon/cookies/1234-1",
    "/repo",
    "/repo/.git",
    "/repo/.git/index",
    "/repo/.git/HEAD",
    "/repo/.git/refs/heads/main",
    "/repo/.git/refs/heads/fsmonitor--daemon",
    "/repo/.git/worktrees/feature/index",
    "/repo/.git/worktrees/feature/logs/HEAD",
    "/repo/.git/worktrees/fsmonitor--daemon/index",
    "/repo/.git/fsmonitor--daemon-backup",
    "/repo/.git/fsmonitor--daemon.ipc-backup",
    "/repo/.git/fsmonitor--daemon.ipc.lock-backup",
  ])
  func preservesWorkingTreeAndGitStateChanges(path: String) {
    let filter = WorktreeFileEventFilter(gitDirectoryURL: URL(fileURLWithPath: "/repo/.git"))
    #expect(filter.shouldRefresh(paths: [path], flags: [0]))
  }

  @Test(arguments: [
    "modules/vendor/child",
    "modules/vendor/child/modules/nested",
    "modules/vendor/child/worktrees/feature",
    "modules/fsmonitor--daemon",
    "worktrees/feature/modules/vendor/child",
  ])
  func ignoresSubmoduleDaemonActivityButPreservesGitState(relativePath: String) throws {
    let root = URL(fileURLWithPath: "/private/tmp").appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let gitDirectory = root.appending(path: ".git")
    let submoduleDirectory = gitDirectory.appending(path: relativePath)
    try FileManager.default.createDirectory(at: submoduleDirectory, withIntermediateDirectories: true)
    if relativePath.hasSuffix("/worktrees/feature") {
      try "../..\n".write(to: submoduleDirectory.appending(path: "commondir"), atomically: true, encoding: .utf8)
    } else {
      try FileManager.default.createDirectory(
        at: submoduleDirectory.appending(path: "objects"), withIntermediateDirectories: true)
    }
    try "ref: refs/heads/main\n".write(
      to: submoduleDirectory.appending(path: "HEAD"), atomically: true, encoding: .utf8)
    let filter = WorktreeFileEventFilter(gitDirectoryURL: gitDirectory)
    let path = submoduleDirectory.path(percentEncoded: false)
    for suffix in ["fsmonitor--daemon/cookies/1234-1", "fsmonitor--daemon.ipc", "fsmonitor--daemon.ipc.lock"] {
      #expect(!filter.shouldRefresh(paths: [path + "/" + suffix], flags: [0]))
    }
    for suffix in ["index", "HEAD", "refs/heads/fsmonitor--daemon", "logs/HEAD"] {
      #expect(filter.shouldRefresh(paths: [path + "/" + suffix], flags: [0]))
    }
    #expect(
      filter.shouldRefresh(
        paths: [path + "/fsmonitor--daemon/cookies/1234-1"],
        flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)]))
  }

  @Test func preservesSubmoduleNamesThatResembleDaemonPaths() {
    let filter = WorktreeFileEventFilter(gitDirectoryURL: URL(fileURLWithPath: "/repo/.git"))
    #expect(filter.shouldRefresh(paths: ["/repo/.git/modules/fsmonitor--daemon/cookies/index"], flags: [0]))
    #expect(filter.shouldRefresh(paths: ["/repo/.git/modules/vendor/fsmonitor--daemon/HEAD"], flags: [0]))
  }

  @Test func refreshesMixedBatchesInEitherOrder() {
    let filter = WorktreeFileEventFilter(gitDirectoryURL: URL(fileURLWithPath: "/repo/.git"))
    let cookie = "/repo/.git/fsmonitor--daemon/cookies/1234-1"
    let source = "/repo/Sources/main.swift"
    #expect(filter.shouldRefresh(paths: [cookie, source], flags: [0, 0]))
    #expect(filter.shouldRefresh(paths: [source, cookie], flags: [0, 0]))
    #expect(!filter.shouldRefresh(paths: [cookie, cookie + "2"], flags: [0, 0]))
  }

  @Test func ignoresCookieCreationAndDeletionFlags() {
    let filter = WorktreeFileEventFilter(gitDirectoryURL: URL(fileURLWithPath: "/repo/.git"))
    let flags = FSEventStreamEventFlags(
      kFSEventStreamEventFlagItemCreated
        | kFSEventStreamEventFlagItemRemoved
        | kFSEventStreamEventFlagItemIsFile
    )
    #expect(
      !filter.shouldRefresh(
        paths: ["/repo/.git/fsmonitor--daemon/cookies/1234-1"], flags: [flags]))
  }

  @Test(arguments: [
    kFSEventStreamEventFlagMustScanSubDirs,
    kFSEventStreamEventFlagUserDropped,
    kFSEventStreamEventFlagKernelDropped,
    kFSEventStreamEventFlagEventIdsWrapped,
    kFSEventStreamEventFlagRootChanged,
    kFSEventStreamEventFlagMount,
    kFSEventStreamEventFlagUnmount,
  ])
  func preservesRecoverySignalsOnIgnoredPaths(flag: Int) {
    let filter = WorktreeFileEventFilter(gitDirectoryURL: URL(fileURLWithPath: "/repo/.git"))
    #expect(
      filter.shouldRefresh(
        paths: ["/repo/.git/fsmonitor--daemon/cookies/1234-1"],
        flags: [FSEventStreamEventFlags(flag)]
      ))
  }

  @Test func refreshesWhenEventMetadataIsIncomplete() {
    let filter = WorktreeFileEventFilter(gitDirectoryURL: URL(fileURLWithPath: "/repo/.git"))
    #expect(filter.shouldRefresh(paths: ["/repo/.git/fsmonitor--daemon/cookies/1234-1"], flags: []))
  }

  @Test func resolvesSymlinkedGitDirectories() throws {
    let root = URL(fileURLWithPath: "/private/tmp").appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let gitDirectory = root.appending(path: "metadata")
    try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
    let link = root.appending(path: "alias")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: gitDirectory)
    let filter = WorktreeFileEventFilter(gitDirectoryURL: link)
    let resolvedPath = gitDirectory.path
    #expect(!filter.shouldRefresh(paths: [resolvedPath + "/fsmonitor--daemon/cookies/1234-1"], flags: [0]))
    #expect(filter.shouldRefresh(paths: [resolvedPath + "/index"], flags: [0]))
  }
}
