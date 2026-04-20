import Foundation
import IdentifiedCollections
import SupacodeSettingsShared

private nonisolated let repositoryClassificationLogger = SupaLogger("RepositoryClassification")

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
  /// Covers the two layouts git actually produces:
  ///   1. `rootURL` IS the metadata dir — `.git/` for a normal repo,
  ///      `.bare` for the naming convention Supacode's `name(for:)`
  ///      helper already recognizes. Lastpathcomponent check.
  ///   2. Standard repo: `rootURL/.git` exists — a directory for
  ///      primary repos, a worktree-pointer file for linked
  ///      worktrees (also the git-wt bare wrapper, where `.git` is
  ///      a pointer file to the sibling bare dir).
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
    // Bare-clone convention: `<name>.git/` with HEAD + objects/ + refs/
    // at the root (what `git clone --bare` produces). The name-only
    // `.bare` / `.git` shortcuts above cover Supacode's own layouts;
    // this catches user-managed bare clones imported via the Open panel.
    guard lastComponent.hasSuffix(".git") else { return false }
    let head = rootURL.appending(path: "HEAD", directoryHint: .notDirectory).path(percentEncoded: false)
    let objects = rootURL.appending(path: "objects", directoryHint: .isDirectory).path(percentEncoded: false)
    let refs = rootURL.appending(path: "refs", directoryHint: .isDirectory).path(percentEncoded: false)
    let hasHead = fileManager.fileExists(atPath: head)
    let hasObjects = fileManager.fileExists(atPath: objects)
    let hasRefs = fileManager.fileExists(atPath: refs)
    if hasHead && hasObjects && hasRefs {
      return true
    }
    // `.git`-suffixed directory missing one of the three structural
    // parts of a bare clone — log so the ambiguous "looks like a
    // damaged bare clone but classifies as a folder" case is
    // observable in telemetry without widening classification and
    // creating false positives for empty `.git` directories.
    repositoryClassificationLogger.warning(
      "Directory ending in .git missing bare-clone structure — "
        + "classified as folder. path=\(rootURL.path(percentEncoded: false)) "
        + "hasHead=\(hasHead) hasObjects=\(hasObjects) hasRefs=\(hasRefs)"
    )
    return false
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
