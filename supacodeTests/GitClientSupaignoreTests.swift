import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

struct GitClientSupaignoreTests {
  /// Builds a repo whose own `.gitignore` ignores several paths, plus untracked
  /// files and a nested git repo, so the plan can be checked for exact
  /// gitignore matching, isolation from the repo's `.gitignore`, negation, and
  /// nested-repo pruning.
  private func makeRepository() async throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "supaignore-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let path = root.path(percentEncoded: false)

    try await Self.runGit(["init", path])
    try await Self.runGit(["-C", path, "config", "user.email", "test@example.com"])
    try await Self.runGit(["-C", path, "config", "user.name", "Test User"])

    try Self.write("build/\n*.log\n*.cache\nsecret.env\nnode_modules/\n", to: root, at: ".gitignore")
    // Committed `supaignore` so the level-3 lookup reads it from the object store.
    try Self.write("secret.env\n", to: root, at: "supaignore")
    try await Self.runGit(["-C", path, "add", ".gitignore", "supaignore"])
    try await Self.runGit(["-C", path, "commit", "-m", "init"])

    // Ignored-by-gitignore files (copy-ignored candidates).
    try Self.write("obj", to: root, at: "build/app.o")
    try Self.write("log", to: root, at: "app.log")
    try Self.write("log", to: root, at: "keep.log")
    try Self.write("cache", to: root, at: "data.cache")
    try Self.write("secret", to: root, at: "secret.env")
    try Self.write("pkg", to: root, at: "node_modules/pkg/index.js")
    // Untracked (not gitignored) files.
    try Self.write("env", to: root, at: ".env")
    try Self.write("notes", to: root, at: "notes.txt")
    // A nested git repo, which git collapses to a single trailing-slash entry.
    let nested = root.appending(path: "vendor-lib")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try await Self.runGit(["init", nested.path(percentEncoded: false)])
    try Self.write("x", to: nested, at: "lib.a")

    return root
  }

  @Test func planExcludesMatchesHonorsNegationAndIsolatesFromGitignore() async throws {
    let root = try await makeRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    // `data.cache` is gitignored but absent from these patterns; it must survive,
    // proving the exclusion query ignores the repo's own `.gitignore`. `!keep.log`
    // re-includes an otherwise-matched file.
    let patterns = "build/\n*.log\n!keep.log\nnode_modules/\nsecret.env\n"
    let plan = try await GitClient().worktreeCopyPlan(
      for: root, copyIgnored: true, copyUntracked: true, excludePatterns: patterns)

    #expect(Set(plan.ignored) == ["keep.log", "data.cache"])
    #expect(Set(plan.untracked) == [".env", "notes.txt"])
    // The nested repo (trailing-slash entry) is never copied.
    #expect(!plan.untracked.contains { $0.hasPrefix("vendor-lib") })
  }

  @Test func endToEndFilteredCopySmokeTest() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appending(path: "supaignore-smoke-\(UUID().uuidString)")
    let destination = fileManager.temporaryDirectory.appending(
      path: "supaignore-dest-\(UUID().uuidString)")
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
    defer {
      try? fileManager.removeItem(at: root)
      try? fileManager.removeItem(at: destination)
    }
    let path = root.path(percentEncoded: false)
    try await Self.runGit(["init", path])
    try await Self.runGit(["-C", path, "config", "user.email", "test@example.com"])
    try await Self.runGit(["-C", path, "config", "user.name", "Test User"])
    // The repo ignores logs, build/, and *.cache; the committed supaignore
    // excludes only logs and build/, so a surviving *.cache proves the filter is
    // isolated from the repo's own .gitignore.
    try Self.write("*.log\nbuild/\n*.cache\n", to: root, at: ".gitignore")
    try Self.write("*.log\nbuild/\n", to: root, at: "supaignore")
    try await Self.runGit(["-C", path, "add", ".gitignore", "supaignore"])
    try await Self.runGit(["-C", path, "commit", "-m", "init"])
    // Ignored files (copy-ignored candidates): logs + build/ are supaignored,
    // data.cache is not.
    try Self.write("log", to: root, at: "app.log")
    try Self.write("obj", to: root, at: "build/out.o")
    try Self.write("cache", to: root, at: "data.cache")
    // Untracked files (copy-untracked candidates), both kept.
    try Self.write("token", to: root, at: ".env")
    try Self.write("notes", to: root, at: "notes.txt")

    // Drive the real resolve -> plan -> copy pipeline through the live client.
    let dependency = GitClientDependency.liveValue
    let absentLayer = fileManager.temporaryDirectory.appending(path: "absent-\(UUID().uuidString)")
    let resolution = await dependency.resolveSupaignore(root, "HEAD", absentLayer, absentLayer)
    guard case .resolved(let patterns) = resolution else {
      Issue.record("expected .resolved, got \(resolution)")
      return
    }
    let plan = try await dependency.worktreeCopyPlan(root, true, true, patterns.value)
    let outcome = await dependency.copyWorktreeArtifacts(plan, root, destination)

    #expect(outcome.failed == 0)
    func copied(_ relativePath: String) -> Bool {
      fileManager.fileExists(atPath: destination.appending(path: relativePath).path(percentEncoded: false))
    }
    // Survivors landed in the new worktree.
    #expect(copied(".env"))
    #expect(copied("notes.txt"))
    #expect(copied("data.cache"))
    // Supaignored files did not.
    #expect(!copied("app.log"))
    #expect(!copied("build/out.o"))
  }

  @Test func negationUnderAnExcludedDirectoryDoesNotReinclude() async throws {
    let root = try await makeRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    // git never descends into an excluded directory, so `!build/app.o` cannot
    // re-include a file under `build/`; it stays excluded. Pinning this stops a
    // future "fix" that pre-expands directories.
    let plan = try await GitClient().worktreeCopyPlan(
      for: root, copyIgnored: true, copyUntracked: false, excludePatterns: "build/\n!build/app.o\n")

    #expect(!plan.ignored.contains("build/app.o"))
  }

  @Test func planHonorsCategoryToggles() async throws {
    let root = try await makeRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    let plan = try await GitClient().worktreeCopyPlan(
      for: root, copyIgnored: false, copyUntracked: true, excludePatterns: "secret.env\n")

    #expect(plan.ignored.isEmpty)
    #expect(Set(plan.untracked) == [".env", "notes.txt"])
  }

  @Test func committedSupaignoreReadsFromObjectStoreEvenWhenAbsentOnDisk() async throws {
    let root = try await makeRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    // Remove the working-tree copy: the lookup must still resolve it from HEAD.
    try FileManager.default.removeItem(at: root.appending(path: "supaignore"))

    // The byte-preserving read keeps the file's trailing newline (unlike the
    // trimmed `String` path); `SupaignoreMerge` normalizes separators downstream.
    let committed = try await GitClient().committedSupaignore(for: root, baseRef: "HEAD")
    #expect(committed == "secret.env\n")
  }

  @Test func committedSupaignorePreservesSignificantBoundaryWhitespace() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "supaignore-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.path(percentEncoded: false)
    try await Self.runGit(["init", path])
    try await Self.runGit(["-C", path, "config", "user.email", "test@example.com"])
    try await Self.runGit(["-C", path, "config", "user.name", "Test User"])
    // A leading space keeps `#keepme` a pattern (not a comment); a trimming read
    // would drop it and silently stop excluding the file.
    try Self.write(" #keepme\n", to: root, at: "supaignore")
    try await Self.runGit(["-C", path, "add", "supaignore"])
    try await Self.runGit(["-C", path, "commit", "-m", "init"])

    let committed = try await GitClient().committedSupaignore(for: root, baseRef: "HEAD")
    #expect(committed == " #keepme\n")
  }

  @Test func committedSupaignoreIsNilWhenTheRefCommitsADirectoryNamedSupaignore() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "supaignore-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.path(percentEncoded: false)
    try await Self.runGit(["init", path])
    try await Self.runGit(["-C", path, "config", "user.email", "test@example.com"])
    try await Self.runGit(["-C", path, "config", "user.name", "Test User"])
    // `git show <ref>:supaignore` on a directory emits a tree listing; the blob
    // gate must treat that as "no committed file", never read the names as patterns.
    try Self.write("inner", to: root, at: "supaignore/inner.txt")
    try await Self.runGit(["-C", path, "add", "supaignore/inner.txt"])
    try await Self.runGit(["-C", path, "commit", "-m", "init"])

    let committed = try await GitClient().committedSupaignore(for: root, baseRef: "HEAD")
    #expect(committed == nil)
  }

  @Test func resolveSupaignoreFailsWhenAGlobalLayerIsUnreadable() async throws {
    let root = try await makeRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    // A directory at the global-layer path can't be read as a file. The read
    // must fail safe (.failed) rather than misreport the layer as absent, which
    // would let `wt` run its unfiltered copy.
    let absentRepoDefault = FileManager.default.temporaryDirectory
      .appending(path: "absent-\(UUID().uuidString)")
    let resolution = await GitClientDependency.liveValue.resolveSupaignore(
      root, "HEAD", root, absentRepoDefault)

    guard case .failed = resolution else {
      Issue.record("expected .failed for an unreadable global layer, got \(resolution)")
      return
    }
  }

  @Test func resolveSupaignoreFailsWhenTheCommittedLookupFails() async throws {
    let root = try await makeRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    // A bad base ref makes the committed lookup throw. Resolution must fail safe
    // rather than degrade to .absent (which would run wt's unfiltered copy).
    let absentGlobal = FileManager.default.temporaryDirectory
      .appending(path: "absent-\(UUID().uuidString)")
    let absentRepoDefault = FileManager.default.temporaryDirectory
      .appending(path: "absent-\(UUID().uuidString)")
    let resolution = await GitClientDependency.liveValue.resolveSupaignore(
      root, "no-such-ref", absentGlobal, absentRepoDefault)

    guard case .failed = resolution else {
      Issue.record("expected .failed for a failing committed lookup, got \(resolution)")
      return
    }
  }

  @Test func resolveMergesThreeOnDiskLayersSoCommittedNegationWinsLast() async throws {
    let root = try await makeRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    let fileManager = FileManager.default
    // The committed layer already excludes `secret.env` (from makeRepository);
    // append the negation that must win over the global `*.env` exclusion.
    try Self.write("secret.env\n!keep.env\n", to: root, at: "supaignore")
    try await Self.runGit(["-C", root.path(percentEncoded: false), "commit", "-am", "supaignore"])

    // Real global + repo-default files on disk, exercising the disk read path
    // (not just the string-level merge unit test).
    let globalURL = fileManager.temporaryDirectory.appending(path: "global-\(UUID().uuidString)")
    let repoDefaultURL = fileManager.temporaryDirectory
      .appending(path: "repo-default-\(UUID().uuidString)")
    defer {
      try? fileManager.removeItem(at: globalURL)
      try? fileManager.removeItem(at: repoDefaultURL)
    }
    try "*.env\n".write(to: globalURL, atomically: true, encoding: .utf8)
    try "*.log\n".write(to: repoDefaultURL, atomically: true, encoding: .utf8)
    // Untracked candidates that the layers filter differently.
    try Self.write("env", to: root, at: "keep.env")

    let resolution = await GitClientDependency.liveValue.resolveSupaignore(
      root, "HEAD", globalURL, repoDefaultURL)
    guard case .resolved(let patterns) = resolution else {
      Issue.record("expected .resolved for three present layers, got \(resolution)")
      return
    }
    let plan = try await GitClient().worktreeCopyPlan(
      for: root, copyIgnored: true, copyUntracked: true, excludePatterns: patterns.value)

    // Global `*.env` excludes `.env`; committed `!keep.env` re-includes it last.
    #expect(Set(plan.untracked) == ["keep.env", "notes.txt"])
    // Repo-default `*.log` excludes `app.log`; `keep.log` also matches `*.log`.
    #expect(!plan.ignored.contains { $0.hasSuffix(".log") })
    #expect(!plan.ignored.contains("secret.env"))
  }

  @Test func remoteFlavorReportsSupaignoreCopyUnsupported() async {
    // Copying into a worktree is local-only; the SSH flavor must not resolve a
    // filter (which would otherwise read local files for a remote repo).
    let dependency = GitClientDependency.ssh(host: RemoteHost(alias: "devbox"))
    let resolution = await dependency.resolveSupaignore(
      URL(fileURLWithPath: "/repo"), "HEAD",
      URL(fileURLWithPath: "/global"), URL(fileURLWithPath: "/repo-default"))
    guard case .failed = resolution else {
      Issue.record("expected .failed for the remote flavor, got \(resolution)")
      return
    }
  }

  @Test func committedSupaignoreThrowsOnGenuineLookupFailure() async throws {
    let root = try await makeRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    // A bad ref is a real failure, not an absent file, so it must throw (letting
    // the caller fail safe) rather than resolve to nil.
    await #expect(throws: (any Error).self) {
      _ = try await GitClient().committedSupaignore(for: root, baseRef: "no-such-ref")
    }
  }

  @Test func committedSupaignoreIsNilWhenAbsentAtRef() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "supaignore-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.path(percentEncoded: false)
    try await Self.runGit(["init", path])
    try await Self.runGit(["-C", path, "config", "user.email", "test@example.com"])
    try await Self.runGit(["-C", path, "config", "user.name", "Test User"])
    try Self.write("hi", to: root, at: "README.md")
    try await Self.runGit(["-C", path, "add", "README.md"])
    try await Self.runGit(["-C", path, "commit", "-m", "init"])

    let committed = try await GitClient().committedSupaignore(for: root, baseRef: "HEAD")
    #expect(committed == nil)
  }

  @Test func effectivePatternsRejectsAnIneffectiveFilter() {
    // Blank and comment-only blobs can't build the payload, so `.resolved` can
    // never carry a filter that excludes nothing while suppressing the wt copy.
    #expect(EffectiveSupaignorePatterns("") == nil)
    #expect(EffectiveSupaignorePatterns("   \n\n") == nil)
    #expect(EffectiveSupaignorePatterns("# only a comment\n") == nil)
    #expect(EffectiveSupaignorePatterns("node_modules/\n")?.value == "node_modules/\n")
  }

  private static func write(_ contents: String, to root: URL, at relativePath: String) throws {
    let url = root.appending(path: relativePath)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try contents.write(to: url, atomically: true, encoding: .utf8)
  }

  @discardableResult
  private static func runGit(_ arguments: [String]) async throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    // Hermetic git: the user's global config must not leak in (gpg signing in
    // particular fails under concurrent test load).
    process.environment = ProcessInfo.processInfo.environment.merging([
      "GIT_CONFIG_GLOBAL": "/dev/null",
      "GIT_CONFIG_SYSTEM": "/dev/null",
    ]) { _, override in override }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try await process.runToExit()
    _ = pipe.fileHandleForReading.readDataToEndOfFile()
    if process.terminationStatus != 0 {
      throw GitSetupError.commandFailed(arguments)
    }
    return ""
  }
}

private enum GitSetupError: Error {
  case commandFailed([String])
}
