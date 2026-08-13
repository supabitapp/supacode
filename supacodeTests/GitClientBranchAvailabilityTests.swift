import Foundation
import Testing

@testable import supacode

/// Classification of a branch name against a repository's local branches, which
/// decides between `git worktree add -b` (new) and `git worktree add <branch>`
/// (reuse) — and which collisions stay refused.
struct GitClientBranchAvailabilityTests {

  // MARK: - Parsing.

  /// `%(worktreepath)` is empty for a branch no worktree holds.
  @Test func branchWithNoWorktreeIsReusable() {
    let output = """
      main\t/repo
      feature/unused\t
      """
    let availability = GitClient.parseBranchAvailability(
      output,
      branch: "feature/unused",
      directoryExists: { _ in true }
    )
    #expect(availability == .reusable(stalePrunePath: nil))
  }

  @Test func branchWithLiveWorktreeIsCheckedOut() {
    let output = "feature/used\t/repo/.worktrees/feature-used"
    let availability = GitClient.parseBranchAvailability(
      output,
      branch: "feature/used",
      directoryExists: { $0 == "/repo/.worktrees/feature-used" }
    )
    #expect(availability == .checkedOut(worktreePath: "/repo/.worktrees/feature-used"))
  }

  /// Stale metadata: git still reports a worktree path, but the directory is
  /// gone. That's prunable, not a real checkout, so the branch stays reusable —
  /// and the path is handed back so the caller knows to prune first.
  @Test func branchWithMissingWorktreeDirectoryIsReusableAfterPrune() {
    let output = "feature/stale\t/repo/.worktrees/deleted"
    let availability = GitClient.parseBranchAvailability(
      output,
      branch: "feature/stale",
      directoryExists: { _ in false }
    )
    #expect(availability == .reusable(stalePrunePath: "/repo/.worktrees/deleted"))
  }

  @Test func unknownBranchIsAbsent() {
    let output = "main\t/repo"
    let availability = GitClient.parseBranchAvailability(
      output,
      branch: "feature/new",
      directoryExists: { _ in true }
    )
    #expect(availability == .absent)
  }

  /// Matches `localBranchNames`, which has always compared case-insensitively.
  @Test func branchMatchIsCaseInsensitive() {
    let output = "Feature/Existing\t"
    let availability = GitClient.parseBranchAvailability(
      output,
      branch: "feature/EXISTING",
      directoryExists: { _ in true }
    )
    #expect(availability == .reusable(stalePrunePath: nil))
  }

  /// Only the first tab separates the fields; a worktree path may contain one.
  @Test func worktreePathContainingATabIsParsedWhole() {
    let output = "feature/x\t/repo/od\td dir"
    let availability = GitClient.parseBranchAvailability(
      output,
      branch: "feature/x",
      directoryExists: { _ in true }
    )
    #expect(availability == .checkedOut(worktreePath: "/repo/od\td dir"))
  }

  /// A branch with no worktree emits `name\t` with nothing after the tab, and
  /// `ShellClient` trims trailing whitespace off the whole command output — so
  /// the *last* such line arrives with its tab gone. Read as a bare name it must
  /// still classify as reusable; skipping it reported the last unused branch as
  /// `.absent`, which sent creation into `git worktree add -b` and a "branch
  /// already exists" failure.
  @Test func trailingTablessLineIsReusable() {
    #expect(
      GitClient.parseBranchAvailability(
        "main\t/repo\nunused\t\nused",
        branch: "used",
        directoryExists: { _ in true }
      ) == .reusable(stalePrunePath: nil)
    )
  }

  /// The same line mid-output, where the tab survives, must agree.
  @Test func tablessAndTabbedFormsAgree() {
    let withTab = GitClient.parseBranchAvailability(
      "used\t\nmain\t/repo",
      branch: "used",
      directoryExists: { _ in true }
    )
    let withoutTab = GitClient.parseBranchAvailability(
      "main\t/repo\nused",
      branch: "used",
      directoryExists: { _ in true }
    )
    #expect(withTab == withoutTab)
    #expect(withTab == .reusable(stalePrunePath: nil))
  }

  /// A bare name still has to match exactly: an unrelated branch must not be
  /// adopted just because its line lost the tab.
  @Test func tablessLineStillRequiresANameMatch() {
    #expect(
      GitClient.parseBranchAvailability(
        "main\t/repo\nused",
        branch: "unused",
        directoryExists: { _ in true }
      ) == .absent
    )
  }

  @Test func emptyOutputIsAbsent() {
    #expect(
      GitClient.parseBranchAvailability("", branch: "anything", directoryExists: { _ in true })
        == .absent
    )
  }

  @Test func emptyBranchNameIsAbsent() {
    #expect(
      GitClient.parseBranchAvailability("main\t/repo", branch: "  ", directoryExists: { _ in true })
        == .absent
    )
  }

  // MARK: - Against a real repository.

  /// End-to-end over real `git`, since the whole point of the query is that its
  /// three answers match what `git worktree add` will actually accept.
  @Test func classifiesBranchesInARealRepository() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = root.appending(path: "repo")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)

    try Self.git(["init", "-q", "-b", "main", repo.path(percentEncoded: false)], in: root)
    try Self.git(["config", "user.email", "test@example.com"], in: repo)
    try Self.git(["config", "user.name", "Test"], in: repo)
    try Self.git(["commit", "-q", "--allow-empty", "-m", "init"], in: repo)
    try Self.git(["branch", "unused"], in: repo)
    try Self.git(["branch", "used"], in: repo)
    let usedWorktree = root.appending(path: "used")
    try Self.git(["worktree", "add", "-q", usedWorktree.path(percentEncoded: false), "used"], in: repo)

    let client = GitClient()
    #expect(try await client.branchAvailability("nonexistent", for: repo) == .absent)
    #expect(try await client.branchAvailability("unused", for: repo) == .reusable(stalePrunePath: nil))

    // The main worktree counts as a live checkout of `main`.
    let mainAvailability = try await client.branchAvailability("main", for: repo)
    guard case .checkedOut = mainAvailability else {
      Issue.record("Expected main to be checked out, got \(mainAvailability)")
      return
    }
    let usedAvailability = try await client.branchAvailability("used", for: repo)
    guard case .checkedOut = usedAvailability else {
      Issue.record("Expected used to be checked out, got \(usedAvailability)")
      return
    }

    // Delete the worktree directory behind git's back: the admin entry survives,
    // so the branch must classify as reusable-after-prune rather than occupied.
    try FileManager.default.removeItem(at: usedWorktree)
    let staleAvailability = try await client.branchAvailability("used", for: repo)
    guard case .reusable(let stalePrunePath) = staleAvailability else {
      Issue.record("Expected stale worktree to leave the branch reusable, got \(staleAvailability)")
      return
    }
    #expect(stalePrunePath != nil)

    // And pruning clears it, which is what makes the subsequent checkout work.
    try await client.pruneWorktrees(for: repo)
    let prunedAvailability = try await client.branchAvailability("used", for: repo)
    if prunedAvailability != .reusable(stalePrunePath: nil) {
      // The classification is derived entirely from git's own output, so report
      // that output: a prune that left the admin entry behind and a path that
      // merely still reads as present on disk are indistinguishable otherwise.
      let repoPath = repo.path(percentEncoded: false)
      let stalePath = usedWorktree.path(percentEncoded: false)
      Issue.record(
        """
        Expected pruned branch to be plainly reusable, got \(prunedAvailability).
        for-each-ref:
        \(Self.gitOutput(["-C", repoPath, "for-each-ref", "--format=%(refname:short)\t%(worktreepath)", "refs/heads"]))
        worktree list:
        \(Self.gitOutput(["-C", repoPath, "worktree", "list", "--porcelain"]))
        stale directory still present: \(FileManager.default.fileExists(atPath: stalePath))
        """
      )
    }
  }

  /// Captures stdout+stderr of a raw git invocation for failure diagnostics.
  /// Deliberately inherits the ambient environment, since that is what
  /// `GitClient` itself runs under.
  private static func gitOutput(_ arguments: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
      try process.run()
    } catch {
      return "<failed to run git: \(error)>"
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(bytes: data, encoding: .utf8) ?? "<non-UTF8 output>"
  }

  /// Hermetic git: the user's global config must not leak in (gpg signing in
  /// particular fails under concurrent test load).
  private static func git(_ arguments: [String], in directory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.environment = ProcessInfo.processInfo.environment.merging([
      "GIT_CONFIG_GLOBAL": "/dev/null",
      "GIT_CONFIG_SYSTEM": "/dev/null",
    ]) { _, override in override }
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
      Issue.record("git \(arguments.joined(separator: " ")) failed: \(process.terminationStatus)")
    }
  }
}
