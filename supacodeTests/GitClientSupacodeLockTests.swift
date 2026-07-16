import Foundation
import Testing

@testable import supacode

struct GitClientSupacodeLockTests {
  @Test func reconcileBackfillsLockOnUnmanagedWorktree() async throws {
    let fixture = try await GitWorktreeFixture()
    defer { fixture.cleanup() }
    try await fixture.addLinkedWorktree(named: "feature-a")
    let adminDir = fixture.adminDirectory(for: "feature-a")
    let lockFile = adminDir.appending(path: "locked")
    #expect(!FileManager.default.fileExists(atPath: lockFile.path(percentEncoded: false)))

    await GitClient().reconcileSupacodeLocks(for: fixture.workURL)

    let reason = try String(contentsOf: lockFile, encoding: .utf8)
    let metadata = GitClient.parseSupacodeLockMetadata(from: reason)
    #expect(metadata?.owner == GitClient.supacodeLockOwner)
    #expect(metadata?.createdAt != nil)
  }

  @Test func reconcilePreservesSupacodeLockWhenWorktreeMissing() async throws {
    let fixture = try await GitWorktreeFixture()
    defer { fixture.cleanup() }
    let worktreeURL = try await fixture.addLinkedWorktree(named: "feature-offline")
    let adminDir = fixture.adminDirectory(for: "feature-offline")
    GitClient.writeSupacodeLock(at: adminDir)
    try FileManager.default.removeItem(at: worktreeURL)

    await GitClient().reconcileSupacodeLocks(for: fixture.workURL)

    // The #338 fix: a transiently missing dir must NOT drop our lock.
    let lockFile = adminDir.appending(path: "locked")
    #expect(FileManager.default.fileExists(atPath: lockFile.path(percentEncoded: false)))
    let adminExists = FileManager.default.fileExists(atPath: adminDir.path(percentEncoded: false))
    #expect(adminExists)
  }

  @Test func reconcileLeavesUserLockUntouched() async throws {
    let fixture = try await GitWorktreeFixture()
    defer { fixture.cleanup() }
    try await fixture.addLinkedWorktree(named: "feature-user-lock")
    let adminDir = fixture.adminDirectory(for: "feature-user-lock")
    let lockFile = adminDir.appending(path: "locked")
    try "user-set".write(to: lockFile, atomically: true, encoding: .utf8)

    await GitClient().reconcileSupacodeLocks(for: fixture.workURL)

    let reason = try String(contentsOf: lockFile, encoding: .utf8)
    #expect(reason.trimmingCharacters(in: .whitespacesAndNewlines) == "user-set")
  }

  @Test func reconcileDoesNotLockBrokenGitdirWorktree() async throws {
    let fixture = try await GitWorktreeFixture()
    defer { fixture.cleanup() }
    let worktreeURL = try await fixture.addLinkedWorktree(named: "feature-broken")
    let adminDir = fixture.adminDirectory(for: "feature-broken")
    // Break the gitdir link: the worktree dir stays, its `.git` pointer is gone.
    try FileManager.default.removeItem(at: worktreeURL.appending(path: ".git"))

    await GitClient().reconcileSupacodeLocks(for: fixture.workURL)

    // Never locked, so the trailing prune reclaims the orphan admin entry.
    #expect(!FileManager.default.fileExists(atPath: adminDir.path(percentEncoded: false)))
  }

  @Test func reconcileReleasesSupacodeLockOnBrokenGitdirWorktree() async throws {
    let fixture = try await GitWorktreeFixture()
    defer { fixture.cleanup() }
    let worktreeURL = try await fixture.addLinkedWorktree(named: "feature-stuck")
    let adminDir = fixture.adminDirectory(for: "feature-stuck")
    // The #616 stuck state: Supacode locked it, then its `.git` link broke, so
    // prune could never reclaim it.
    GitClient.writeSupacodeLock(at: adminDir)
    try FileManager.default.removeItem(at: worktreeURL.appending(path: ".git"))

    await GitClient().reconcileSupacodeLocks(for: fixture.workURL)

    // The lock is released and the orphan admin entry is pruned.
    #expect(!FileManager.default.fileExists(atPath: adminDir.path(percentEncoded: false)))
  }

  @Test func reconcilePreservesUserLockOnBrokenGitdirWorktree() async throws {
    let fixture = try await GitWorktreeFixture()
    defer { fixture.cleanup() }
    let worktreeURL = try await fixture.addLinkedWorktree(named: "feature-user-broken")
    let adminDir = fixture.adminDirectory(for: "feature-user-broken")
    let lockFile = adminDir.appending(path: "locked")
    try "user-set".write(to: lockFile, atomically: true, encoding: .utf8)
    try FileManager.default.removeItem(at: worktreeURL.appending(path: ".git"))

    await GitClient().reconcileSupacodeLocks(for: fixture.workURL)

    // A user `git worktree lock --reason` is never dropped, so the entry survives.
    let reason = try String(contentsOf: lockFile, encoding: .utf8)
    #expect(reason.trimmingCharacters(in: .whitespacesAndNewlines) == "user-set")
  }

  @Test func reconcileKeepsLockWhenGitdirPointerIsPresentButUnreadable() async throws {
    let fixture = try await GitWorktreeFixture()
    defer { fixture.cleanup() }
    let worktreeURL = try await fixture.addLinkedWorktree(named: "feature-garbled")
    let adminDir = fixture.adminDirectory(for: "feature-garbled")
    GitClient.writeSupacodeLock(at: adminDir)
    // Only a MISSING `.git` counts as broken; a present-but-garbage pointer must
    // not be treated as broken, so a valid lock is never dropped on a transient.
    let gitPointer = worktreeURL.appending(path: ".git")
    try FileManager.default.removeItem(at: gitPointer)
    try "garbage".write(to: gitPointer, atomically: true, encoding: .utf8)

    await GitClient().reconcileSupacodeLocks(for: fixture.workURL)

    let lockFile = adminDir.appending(path: "locked")
    let reason = try String(contentsOf: lockFile, encoding: .utf8)
    #expect(GitClient.parseSupacodeLockMetadata(from: reason)?.owner == GitClient.supacodeLockOwner)
  }

  @Test func reconcileHandlesRelativePathGitdir() async throws {
    let fixture = try await GitWorktreeFixture()
    defer { fixture.cleanup() }
    try await fixture.addLinkedWorktree(named: "feature-relative", useRelativePaths: true)
    let adminDir = fixture.adminDirectory(for: "feature-relative")
    let lockFile = adminDir.appending(path: "locked")

    await GitClient().reconcileSupacodeLocks(for: fixture.workURL)

    // Regression for git 2.48+ with `worktree.useRelativePaths`: the
    // admin gitdir is `../../../<worktree>/.git` and must resolve
    // against the admin dir, not CWD.
    let reason = try String(contentsOf: lockFile, encoding: .utf8)
    let metadata = GitClient.parseSupacodeLockMetadata(from: reason)
    #expect(metadata?.owner == GitClient.supacodeLockOwner)
  }

  @Test func reconcileWorksWithProductionStyleRootURL() async throws {
    let fixture = try await GitWorktreeFixture()
    defer { fixture.cleanup() }
    try await fixture.addLinkedWorktree(named: "feature-bare-url")
    let adminDir = fixture.adminDirectory(for: "feature-bare-url")
    let lockFile = adminDir.appending(path: "locked")
    // Production builds the root via `URL(fileURLWithPath: $0)` without
    // a directoryHint (RepositoriesFeature.swift). Mirror that exactly.
    let productionStyleRoot = URL(fileURLWithPath: fixture.workURL.path(percentEncoded: false))

    await GitClient().reconcileSupacodeLocks(for: productionStyleRoot)

    #expect(FileManager.default.fileExists(atPath: lockFile.path(percentEncoded: false)))
  }

  @Test func removeWorktreeReleasesSupacodeLock() async throws {
    let fixture = try await GitWorktreeFixture()
    defer { fixture.cleanup() }
    let worktreeURL = try await fixture.addLinkedWorktree(named: "feature-remove")
    let adminDir = fixture.adminDirectory(for: "feature-remove")
    GitClient.writeSupacodeLock(at: adminDir)
    let worktree = Worktree(
      id: WorktreeID(worktreeURL.path(percentEncoded: false)),
      kind: .git,
      name: "feature-remove",
      detail: "feature-remove",
      workingDirectory: worktreeURL,
      repositoryRootURL: fixture.workURL
    )

    _ = try await GitClient().removeWorktree(worktree, deleteBranch: false)

    let adminExists = FileManager.default.fileExists(atPath: adminDir.path(percentEncoded: false))
    #expect(!adminExists)
  }

  @Test func removeWorktreeCleansLockedOrphan() async throws {
    let fixture = try await GitWorktreeFixture()
    defer { fixture.cleanup() }
    let worktreeURL = try await fixture.addLinkedWorktree(named: "feature-orphan-delete")
    let adminDir = fixture.adminDirectory(for: "feature-orphan-delete")
    GitClient.writeSupacodeLock(at: adminDir)
    try FileManager.default.removeItem(at: worktreeURL)
    let worktree = Worktree(
      id: WorktreeID(worktreeURL.path(percentEncoded: false)),
      kind: .git,
      name: "feature-orphan-delete",
      detail: "feature-orphan-delete",
      workingDirectory: worktreeURL,
      repositoryRootURL: fixture.workURL,
      isMissing: true
    )

    _ = try await GitClient().removeWorktree(worktree, deleteBranch: false)

    let adminExists = FileManager.default.fileExists(atPath: adminDir.path(percentEncoded: false))
    #expect(!adminExists)
  }

  @Test func removeWorktreeCleansLockedOrphanWithBranchDelete() async throws {
    let fixture = try await GitWorktreeFixture()
    defer { fixture.cleanup() }
    let worktreeURL = try await fixture.addLinkedWorktree(named: "feature-orphan-branch")
    let adminDir = fixture.adminDirectory(for: "feature-orphan-branch")
    GitClient.writeSupacodeLock(at: adminDir)
    try FileManager.default.removeItem(at: worktreeURL)
    let worktree = Worktree(
      id: WorktreeID(worktreeURL.path(percentEncoded: false)),
      kind: .git,
      name: "feature-orphan-branch",
      detail: "feature-orphan-branch",
      workingDirectory: worktreeURL,
      repositoryRootURL: fixture.workURL,
      isMissing: true
    )

    _ = try await GitClient().removeWorktree(worktree, deleteBranch: true)

    let adminExists = FileManager.default.fileExists(atPath: adminDir.path(percentEncoded: false))
    #expect(!adminExists)
    let branches = try await GitClient().localBranchNames(for: fixture.workURL)
    #expect(!branches.contains("feature-orphan-branch"))
  }

  @Test func writeSupacodeLockProducesParseableMetadata() async throws {
    let fixture = try await GitWorktreeFixture()
    defer { fixture.cleanup() }
    try await fixture.addLinkedWorktree(named: "feature-lock-on-create")
    let worktreeURL = fixture.containerURL.appending(path: "feature-lock-on-create")
    let adminDir = try #require(GitClient.adminDirectory(forWorktreeAt: worktreeURL))

    // Mirrors the call `createWorktreeStream` makes on success.
    GitClient.writeSupacodeLock(at: adminDir)

    let lockFile = adminDir.appending(path: "locked")
    let reason = try String(contentsOf: lockFile, encoding: .utf8)
    let metadata = try #require(GitClient.parseSupacodeLockMetadata(from: reason))
    #expect(metadata.owner == GitClient.supacodeLockOwner)
    #expect(metadata.createdAt != nil)
  }

  @Test func lockPayloadRoundTripsThroughParser() throws {
    let payload = GitClient.currentSupacodeLockPayload()
    let metadata = try #require(GitClient.parseSupacodeLockMetadata(from: payload))
    #expect(metadata.owner == GitClient.supacodeLockOwner)
    #expect(metadata.createdAt != nil)
  }

  @Test func parserRejectsForeignOwner() {
    let foreign = #"{"owner":"someone-else","version":"1.0.0"}"#
    #expect(GitClient.parseSupacodeLockMetadata(from: foreign) == nil)
  }

  @Test func parserRejectsNonJSONReason() {
    #expect(GitClient.parseSupacodeLockMetadata(from: "Managed by Supacode") == nil)
    #expect(GitClient.parseSupacodeLockMetadata(from: "") == nil)
  }

  @Test func reconcileBackfillsLockOnBareRepository() async throws {
    let tempRoot = URL(filePath: "/tmp", directoryHint: .isDirectory)
    let id = UUID().uuidString
    let containerURL = tempRoot.appending(path: "supacode-bare-\(id)", directoryHint: .isDirectory)
    let bareURL = containerURL.appending(path: "origin.git", directoryHint: .isDirectory)
    let seedURL = containerURL.appending(path: "seed", directoryHint: .isDirectory)
    let worktreeURL = containerURL.appending(path: "feature", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: containerURL) }
    try await GitWorktreeFixture.git(["init", seedURL.path(percentEncoded: false)])
    try await GitWorktreeFixture.git([
      "-C", seedURL.path(percentEncoded: false), "config", "user.email", "test@example.com",
    ])
    try await GitWorktreeFixture.git([
      "-C", seedURL.path(percentEncoded: false), "config", "user.name", "Test User",
    ])
    let readme = seedURL.appending(path: "README.md")
    try "hello".write(to: readme, atomically: true, encoding: .utf8)
    try await GitWorktreeFixture.git(["-C", seedURL.path(percentEncoded: false), "add", "README.md"])
    try await GitWorktreeFixture.git(["-C", seedURL.path(percentEncoded: false), "commit", "-m", "init"])
    try await GitWorktreeFixture.git(["-C", seedURL.path(percentEncoded: false), "branch", "-M", "main"])
    try await GitWorktreeFixture.git(["init", "--bare", bareURL.path(percentEncoded: false)])
    try await GitWorktreeFixture.git([
      "-C", seedURL.path(percentEncoded: false),
      "push", bareURL.path(percentEncoded: false), "main",
    ])
    try await GitWorktreeFixture.git([
      "-C", bareURL.path(percentEncoded: false), "worktree", "add",
      worktreeURL.path(percentEncoded: false), "main",
    ])
    let adminDir =
      bareURL
      .appending(path: "worktrees", directoryHint: .isDirectory)
      .appending(path: "feature", directoryHint: .isDirectory)
    let lockFile = adminDir.appending(path: "locked")
    #expect(!FileManager.default.fileExists(atPath: lockFile.path(percentEncoded: false)))

    await GitClient().reconcileSupacodeLocks(for: bareURL)

    let reason = try String(contentsOf: lockFile, encoding: .utf8)
    let metadata = GitClient.parseSupacodeLockMetadata(from: reason)
    #expect(metadata?.owner == GitClient.supacodeLockOwner)
  }

  @Test func adminDirectoryResolvesPointerFile() async throws {
    let fixture = try await GitWorktreeFixture()
    defer { fixture.cleanup() }
    let worktreeURL = try await fixture.addLinkedWorktree(named: "feature-resolve")
    let expected = fixture.adminDirectory(for: "feature-resolve")

    let resolved = GitClient.adminDirectory(forWorktreeAt: worktreeURL)

    #expect(resolved?.standardizedFileURL == expected.standardizedFileURL)
  }
}

private struct GitWorktreeFixture {
  let containerURL: URL
  let workURL: URL

  init() async throws {
    let tempRoot = URL(filePath: "/tmp", directoryHint: .isDirectory)
    let id = UUID().uuidString
    containerURL = tempRoot.appending(
      path: "supacode-lock-\(id)",
      directoryHint: URL.DirectoryHint.isDirectory
    )
    try FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: true)
    workURL = containerURL.appending(path: "main", directoryHint: .isDirectory)
    try await Self.git(["init", workURL.path(percentEncoded: false)])
    try await Self.git([
      "-C", workURL.path(percentEncoded: false), "config", "user.email", "test@example.com",
    ])
    try await Self.git([
      "-C", workURL.path(percentEncoded: false), "config", "user.name", "Test User",
    ])
    let readmeURL = workURL.appending(path: "README.md")
    try "hello".write(to: readmeURL, atomically: true, encoding: .utf8)
    try await Self.git(["-C", workURL.path(percentEncoded: false), "add", "README.md"])
    try await Self.git(["-C", workURL.path(percentEncoded: false), "commit", "-m", "init"])
    try await Self.git(["-C", workURL.path(percentEncoded: false), "branch", "-M", "main"])
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: containerURL)
  }

  @discardableResult
  func addLinkedWorktree(named name: String, useRelativePaths: Bool = false) async throws -> URL {
    let worktreeURL = containerURL.appending(path: name, directoryHint: .isDirectory)
    var args = ["-C", workURL.path(percentEncoded: false)]
    if useRelativePaths {
      args += ["-c", "worktree.useRelativePaths=true"]
    }
    args += ["worktree", "add", "-b", name, worktreeURL.path(percentEncoded: false)]
    try await Self.git(args)
    return worktreeURL.standardizedFileURL
  }

  func adminDirectory(for name: String) -> URL {
    workURL
      .appending(path: ".git", directoryHint: .isDirectory)
      .appending(path: "worktrees", directoryHint: .isDirectory)
      .appending(path: name, directoryHint: .isDirectory)
      .standardizedFileURL
  }

  @discardableResult
  static func git(_ arguments: [String]) async throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    // Hermetic git: the user's global config must not leak in (gpg signing
    // in particular fails under concurrent test load).
    process.environment = ProcessInfo.processInfo.environment.merging([
      "GIT_CONFIG_GLOBAL": "/dev/null",
      "GIT_CONFIG_SYSTEM": "/dev/null",
    ]) { _, override in override }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try await process.runToExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    if process.terminationStatus != 0 {
      throw GitFixtureError(output: output)
    }
    return output
  }
}

private struct GitFixtureError: Error {
  let output: String
}
