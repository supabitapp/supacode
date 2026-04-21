import Foundation
import IdentifiedCollections
import SupacodeSettingsShared

struct Repository: Identifiable, Hashable, Sendable {
  let id: String
  let rootURL: URL
  let name: String
  let worktrees: IdentifiedArrayOf<Worktree>
  // Runtime classification — `false` means the rootURL is a plain
  // directory (no `.git` / `.bare`) and the repository is treated as
  // a non-git folder. Persistence is unchanged; this flips freely on
  // reload when the directory is (un)initialized as a git repo.
  let isGitRepository: Bool

  init(
    id: String,
    rootURL: URL,
    name: String,
    worktrees: IdentifiedArrayOf<Worktree>,
    isGitRepository: Bool = true
  ) {
    self.id = id
    self.rootURL = rootURL
    self.name = name
    self.worktrees = worktrees
    self.isGitRepository = isGitRepository
  }

  var initials: String {
    Self.initials(from: name)
  }

  /// Synchronous check for whether a root URL is a git repository.
  /// Approximates git's own `is_git_directory()` heuristic so the
  /// result matches what `git` itself would accept as a repo root:
  ///   1. `.bare` / `.git` root names — cheap short-circuit covering
  ///      Supacode's own `.bare` layout and the common `*.git` bare
  ///      convention when the root is literally the metadata dir.
  ///   2. `rootURL/.git` exists (file or directory) — standard
  ///      worktree root. Primary repo, linked worktree pointer,
  ///      submodule, `--separate-git-dir` pointer, or the git-wt
  ///      bare wrapper all surface through this one check.
  ///   3. `HEAD` + `objects` + `refs` all present at the root — any
  ///      git dir (bare or otherwise) regardless of naming. Catches
  ///      bare repos whose directory name does not end in `.git`.
  ///      `HEAD` must be a regular file; git itself rejects a
  ///      `HEAD` directory, so a directory with three child dirs
  ///      named HEAD / objects / refs is not a repo.
  /// Pure FileManager call — safe to invoke off the main actor from
  /// the `GitClientDependency` closure.
  nonisolated static func isGitRepository(at rootURL: URL) -> Bool {
    let fileManager = FileManager.default
    let lastComponent = rootURL.lastPathComponent
    if lastComponent == ".bare" || lastComponent == ".git" {
      return true
    }
    let dotGitPath =
      rootURL
      .appending(path: ".git", directoryHint: .notDirectory)
      .path(percentEncoded: false)
    if fileManager.fileExists(atPath: dotGitPath) {
      return true
    }
    let headPath = rootURL.appending(path: "HEAD", directoryHint: .notDirectory).path(percentEncoded: false)
    let objectsPath = rootURL.appending(path: "objects", directoryHint: .isDirectory).path(percentEncoded: false)
    let refsPath = rootURL.appending(path: "refs", directoryHint: .isDirectory).path(percentEncoded: false)
    var headIsDirectory: ObjCBool = false
    let headExists = fileManager.fileExists(atPath: headPath, isDirectory: &headIsDirectory)
    guard headExists, !headIsDirectory.boolValue else { return false }
    return fileManager.fileExists(atPath: objectsPath)
      && fileManager.fileExists(atPath: refsPath)
  }

  /// Prefix on folder-synthetic worktree ids. Single source of truth
  /// so reducer call sites that need to recover the repo id from a
  /// folder worktree id (see `repositoryID(fromFolderWorktreeID:)`)
  /// stay in sync with the constructor below.
  nonisolated static let folderWorktreeIDPrefix = "folder:"

  /// Stable synthetic worktree id for folder repositories. Keeps the
  /// existing `SidebarSelection.worktree(id)` + terminal-manager
  /// plumbing unchanged — folders reuse the same selection path.
  nonisolated static func folderWorktreeID(for rootURL: URL) -> Worktree.ID {
    folderWorktreeIDPrefix + rootURL.standardizedFileURL.path(percentEncoded: false)
  }

  /// Round-trip for `folderWorktreeID(for:)`: recover the owning
  /// `Repository.ID` (the standardized path) from a folder-synthetic
  /// worktree id. Returns `nil` for non-folder ids so callers can
  /// distinguish "this isn't a folder worktree" from "this is a
  /// folder worktree without a known repo."
  nonisolated static func repositoryID(
    fromFolderWorktreeID worktreeID: Worktree.ID
  ) -> Repository.ID? {
    guard worktreeID.hasPrefix(folderWorktreeIDPrefix) else { return nil }
    return String(worktreeID.dropFirst(folderWorktreeIDPrefix.count))
  }

  /// Whether `worktreeID` is a folder-synthetic worktree id (as
  /// produced by `folderWorktreeID(for:)`). Cheaper than calling
  /// `repositoryID(fromFolderWorktreeID:)` when the caller only
  /// wants the discrimination.
  nonisolated static func isFolderWorktreeID(_ worktreeID: Worktree.ID) -> Bool {
    worktreeID.hasPrefix(folderWorktreeIDPrefix)
  }

  static func name(for rootURL: URL) -> String {
    let name = rootURL.lastPathComponent
    if name == ".bare" || name == ".git" {
      let parentName = rootURL.deletingLastPathComponent().lastPathComponent
      if !parentName.isEmpty, parentName != "/" {
        return parentName
      }
    }
    if name.isEmpty {
      return rootURL.path(percentEncoded: false)
    }
    return name
  }

  static func initials(from name: String) -> String {
    var parts: [String] = []
    var current = ""
    for character in name {
      if character.isLetter || character.isNumber {
        current.append(character)
      } else if !current.isEmpty {
        parts.append(current)
        current = ""
      }
    }
    if !current.isEmpty {
      parts.append(current)
    }
    let initials: String
    if parts.count >= 2 {
      let first = parts[0].prefix(1)
      let second = parts[1].prefix(1)
      initials = String(first + second)
    } else if let part = parts.first {
      initials = String(part.prefix(2))
    } else {
      initials = String(name.prefix(2))
    }
    return initials.uppercased()
  }
}
