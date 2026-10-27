import Foundation

/// What sits at a worktree target before `wt` runs.
nonisolated enum WorktreeTargetState: Equatable, Sendable {
  case absent
  case emptyDirectory
  /// A file, any symlink, a non-empty directory, or anything that can't be read.
  case occupied
}

/// How a requested branch name stands against the repository's local branches.
nonisolated enum GitBranchAvailability: Equatable, Sendable {
  case absent
  /// The branch exists and no worktree has it checked out.
  case reusable
  /// Checked out in the worktree at this path. Git allows one checkout per branch, and `wt sw`
  /// would hand that worktree back instead of failing.
  case checkedOut(String)
}

/// The branch and directory a failed creation may reap, and only if git registered them as a pair.
nonisolated struct WorktreeCreationCleanupTarget: Equatable, Sendable {
  let branchName: String
  let directory: URL
  /// An empty folder the user already had there, restored after a reap.
  let directoryPreexisted: Bool
  /// The commit `wt` branches from; a leftover branch must still point there to be deleted.
  var baseCommit: String?
  /// Git started `worktree add` for this branch; nothing is reaped without it.
  var startedWorktreeAdd = false
  /// The branch predates this creation, so a reap removes only the worktree, never the branch.
  var reusesBranch = false

  /// Whether `line` is git's `worktree add` announcement for this branch (stderr, `LC_ALL=C`).
  func isWorktreeAddAnnouncement(_ line: String) -> Bool {
    let announcement = reusesBranch ? "checking out '\(branchName)'" : "new branch '\(branchName)'"
    return line.trimmingCharacters(in: .whitespacesAndNewlines) == "Preparing worktree (\(announcement))"
  }
}

/// Whether a creation's result is the worktree it claimed, or one `wt` resolved to instead.
nonisolated enum WorktreeCreationOwnership: Equatable, Sendable {
  case created(WorktreeCreationCleanupTarget)
  /// `wt` handed back a worktree that predates this creation, which a cancel must not delete.
  case adopted
}

/// Checks that keep a worktree creation from landing on refs or folders it doesn't own.
nonisolated enum WorktreeCreationPreflight {
  /// Names a new branch can't take, in any case.
  struct TakenNames: Equatable, Sendable {
    /// Existing branches, which also reserve their ref namespace.
    var branches: Set<String>
    /// Worktree display names (a detached worktree's folder leaf), matched exactly.
    var worktrees: Set<String> = []
    /// In-flight creations, which reserve their name and namespace even for a reuse.
    var inFlight: Set<String> = []
  }

  enum Rejection: Error, Equatable, Sendable {
    case nameTaken
    case branchCheckedOut(worktreePath: String)
    /// A reuse found the branch created or deleted between its two checks.
    case branchChanged
    case namespaceConflict(branch: String)
    case folderOccupied(URL)
    case insideWorktree(URL, worktreeName: String)

    var title: String {
      switch self {
      case .nameTaken: "Branch name already exists"
      case .branchCheckedOut: "Branch already checked out"
      case .branchChanged: "Branch changed during creation"
      case .namespaceConflict: "Branch name conflicts with an existing branch"
      case .folderOccupied: "Worktree folder already exists"
      case .insideWorktree: "Worktree folder is inside another worktree"
      }
    }

    var message: String {
      switch self {
      case .nameTaken:
        "Choose a different branch name and try again."
      case .branchCheckedOut(let worktreePath):
        "It's checked out at '\(worktreePath)', and git allows one checkout per branch. "
          + "Open that worktree, or choose a different branch name."
      case .branchChanged:
        "The branch was created or deleted while the worktree was being prepared. Try again."
      case .namespaceConflict(let branch):
        "Git can't create this branch while '\(branch)' exists, since one would have to be "
          + "a folder of the other. Choose a different branch name."
      case .folderOccupied(let directory):
        "'\(directory.path(percentEncoded: false))' already exists. Choose a different branch or worktree name."
      case .insideWorktree(let directory, let worktreeName):
        "'\(directory.path(percentEncoded: false))' is inside the '\(worktreeName)' worktree. "
          + "Choose a different location."
      }
    }
  }

  /// Clears `branchName` for `wt` at `targetDirectory`, yielding the only target a failure may reap.
  /// `existingBranch` is classified only when the caller opted to reuse an existing branch: a
  /// `.reusable` one may keep its name, a `.checkedOut` one is refused, and `.absent` creates it.
  static func claim(
    branchName: String,
    targetDirectory: URL,
    targetState: WorktreeTargetState,
    takenNames: TakenNames,
    worktrees: [Worktree],
    existingBranch: GitBranchAvailability = .absent
  ) -> Result<WorktreeCreationCleanupTarget, Rejection> {
    if case .checkedOut(let worktreePath) = existingBranch {
      return .failure(.branchCheckedOut(worktreePath: worktreePath))
    }
    let reusesBranch = existingBranch == .reusable
    let lowercasedName = branchName.lowercased()
    let blockingNames = takenNames.worktrees.union(takenNames.inFlight)
      .union(reusesBranch ? [] : takenNames.branches)
    for taken in blockingNames where taken.lowercased() == lowercasedName {
      return .failure(.nameTaken)
    }
    if let conflict = conflictingBranch(for: branchName, among: takenNames.branches.union(takenNames.inFlight)) {
      return .failure(.namespaceConflict(branch: conflict))
    }
    if targetState == .occupied {
      return .failure(.folderOccupied(targetDirectory))
    }
    if let enclosing = enclosingWorktree(of: targetDirectory, in: worktrees) {
      return .failure(.insideWorktree(targetDirectory, worktreeName: enclosing.name))
    }
    return .success(
      WorktreeCreationCleanupTarget(
        branchName: branchName,
        directory: targetDirectory,
        directoryPreexisted: targetState == .emptyDirectory,
        reusesBranch: reusesBranch
      )
    )
  }

  /// The name sharing a ref namespace with `name` (`a` vs `a/b`). Case-insensitive, since loose
  /// refs live on a case-insensitive APFS volume; that over-rejects on case-sensitive ones.
  static func conflictingBranch(for name: String, among branches: Set<String>) -> String? {
    let lowercasedName = name.lowercased()
    for branch in branches.sorted() {
      let lowercasedBranch = branch.lowercased()
      guard lowercasedBranch.hasPrefix(lowercasedName + "/") || lowercasedName.hasPrefix(lowercasedBranch + "/")
      else { continue }
      return branch
    }
    return nil
  }

  /// Every parent namespace of `branches` (`a` and `a/b` for `a/b/c`), lowercased.
  static func namespaces(of branches: Set<String>) -> Set<String> {
    var namespaces: Set<String> = []
    for branch in branches {
      let components = branch.lowercased().split(separator: "/", omittingEmptySubsequences: false)
      guard components.count > 1 else { continue }
      for length in 1..<components.count {
        namespaces.insert(components.prefix(length).joined(separator: "/"))
      }
    }
    return namespaces
  }

  /// The linked worktree whose directory is or encloses `directory`, compared case-insensitively
  /// like APFS. The main worktree is skipped: a repo-relative base (`.worktrees`) lives inside it.
  static func enclosingWorktree(of directory: URL, in worktrees: [Worktree]) -> Worktree? {
    let target = canonicalComponents(of: directory).map { $0.lowercased() }
    for worktree in worktrees {
      let candidate = canonicalComponents(of: worktree.workingDirectory).map { $0.lowercased() }
      let root = canonicalComponents(of: worktree.repositoryRootURL).map { $0.lowercased() }
      guard candidate != root, target.starts(with: candidate) else { continue }
      return worktree
    }
    return nil
  }

  /// Whether both URLs name the same directory once symlinks (e.g. `/tmp`) resolve.
  static func isSameDirectory(_ lhs: URL, _ rhs: URL) -> Bool {
    canonicalComponents(of: lhs) == canonicalComponents(of: rhs)
  }

  /// Path components with symlinks resolved on the deepest existing ancestor, so a
  /// not-yet-created path compares equal to its future realpath.
  private static func canonicalComponents(of url: URL) -> [String] {
    var existing = url.standardizedFileURL
    var missing: [String] = []
    while existing.pathComponents.count > 1,
      !FileManager.default.fileExists(atPath: existing.path(percentEncoded: false))
    {
      missing.insert(existing.lastPathComponent, at: 0)
      existing = existing.deletingLastPathComponent()
    }
    return existing.resolvingSymlinksInPath().standardizedFileURL.pathComponents + missing
  }
}
