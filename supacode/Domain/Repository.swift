import Foundation
import IdentifiedCollections
import SupacodeSettingsShared

nonisolated struct Repository: Identifiable, Hashable, Sendable {
  /// Where the repository lives (local URL or remote host + path). The single
  /// source of truth for local-vs-remote: `id`, `host`, `rootURL`, and the
  /// FileManager-safe `localRootURL` all derive from it.
  let location: RepositoryLocation
  /// Git repo vs plain directory. Flips freely on reload when the root is
  /// (un)initialized as a git repo; persistence is unchanged.
  let kind: RepositoryKind
  let name: String
  let worktrees: IdentifiedArrayOf<Worktree>

  /// Branded id derived from the location (local: absolute path; remote:
  /// `remote://<user@host:port><path>`). Stored so legacy/test call sites can
  /// pass it explicitly, but production construction always derives it.
  let id: RepositoryID

  /// SSH host this repository lives on, or `nil` for a local repository.
  var host: RemoteHost? { location.host }

  var isGitRepository: Bool { kind == .git }

  /// Display / settings-key URL. For a remote repo this is a synthetic
  /// `file://` over the remote path; never hand it to FileManager.
  var rootURL: URL { location.displayURL }

  /// The on-disk URL for a local repository, `nil` for a remote one. Use this
  /// for any FileManager work so a remote path can't be touched by accident.
  var localRootURL: URL? { location.localRootURL }

  /// Designated initializer: id is derived from the location.
  init(
    location: RepositoryLocation,
    kind: RepositoryKind,
    name: String,
    worktrees: IdentifiedArrayOf<Worktree>
  ) {
    self.location = location
    self.kind = kind
    self.name = name
    self.worktrees = worktrees
    self.id = location.id
  }

  /// Back-compat initializer: builds the location from `rootURL` + `host`.
  /// Kept so existing call sites (and tests) compile while the model migrates.
  init(
    id: RepositoryID,
    rootURL: URL,
    name: String,
    worktrees: IdentifiedArrayOf<Worktree>,
    isGitRepository: Bool = true,
    host: RemoteHost? = nil
  ) {
    if let host {
      self.location = .remote(host, path: rootURL.path(percentEncoded: false))
    } else {
      self.location = .local(rootURL)
    }
    self.kind = isGitRepository ? .git : .folder
    self.name = name
    self.worktrees = worktrees
    self.id = id
  }

  /// Copy preserving `location` and `kind`, swapping only the worktree set, so a
  /// remote repo's host and kind survive an in-state worktree mutation.
  func withWorktrees(_ worktrees: IdentifiedArrayOf<Worktree>) -> Repository {
    Repository(location: location, kind: kind, name: name, worktrees: worktrees)
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

  /// Stable synthetic worktree id for a local folder repository, derived from
  /// the owning repo id so it round-trips through `WorktreeID.folderRepositoryID`.
  nonisolated static func folderWorktreeID(for rootURL: URL) -> Worktree.ID {
    WorktreeID.folder(repositoryID: RepositoryLocation.local(rootURL.standardizedFileURL).id)
  }

  /// Recover the owning `Repository.ID` from a folder-synthetic worktree id.
  /// `nil` for non-folder ids.
  nonisolated static func repositoryID(
    fromFolderWorktreeID worktreeID: Worktree.ID
  ) -> Repository.ID? {
    worktreeID.folderRepositoryID
  }

  /// Whether `worktreeID` is a folder-synthetic worktree id.
  nonisolated static func isFolderWorktreeID(_ worktreeID: Worktree.ID) -> Bool {
    worktreeID.isFolder
  }

  /// Shared trim + fallback for the sidebar header and the highlight-row tag.
  /// Trims `custom`; falls back to `fallback` when the trimmed value is empty.
  static func sidebarDisplayName(custom: String?, fallback: String) -> String {
    guard let trimmed = custom?.trimmingCharacters(in: .whitespacesAndNewlines),
      !trimmed.isEmpty
    else {
      return fallback
    }
    return trimmed
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
