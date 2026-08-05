import Foundation
import SupacodeSettingsShared

nonisolated struct Worktree: Identifiable, Hashable, Sendable {
  /// Branded id derived from the location (local: working-dir path; remote:
  /// `<user@host:port><path>`). Independent of git-vs-folder, which is a runtime
  /// classification carried in `kind`, not baked into the id. Stored so
  /// legacy/test call sites can pass it explicitly; production derives it.
  let id: WorktreeID
  /// Where the worktree lives. Single source of truth for `host`,
  /// `workingDirectory`, `repositoryRootURL`, and the FileManager-safe
  /// `localWorkingDirectory`.
  let location: WorktreeLocation
  /// Git worktree vs folder synthetic. Runtime classification (a directory can
  /// be (un)initialized as a git repo), so it lives here, not in the id.
  let kind: RepositoryKind
  let name: String
  let detail: String
  let createdAt: Date?
  /// The admin entry exists but the working dir is gone on disk.
  /// Drives the orphan UI (warning icon, gated open actions).
  let isMissing: Bool
  /// `false` for detached-HEAD git worktrees and folder synthetics. Gates
  /// branch-targeted actions so they don't reach a `git branch -m` call
  /// that has no real ref to operate on.
  let isAttached: Bool
  /// Main-worktree geometry (working directory == repository root), computed
  /// once here since `location` is immutable, so roster-wide scans read a
  /// stored flag instead of re-deriving URLs per call (gh-764).
  let isMainWorktree: Bool

  /// SSH host this worktree lives on, or `nil` for a local worktree.
  var host: RemoteHost? { location.host }

  /// Display / env-var working-directory URL. For a remote worktree this is a
  /// synthetic `file://` over the remote path; never hand it to FileManager.
  var workingDirectory: URL { location.workingDirectory }
  var repositoryRootURL: URL { location.repositoryRootURL }

  /// The on-disk working directory for a local worktree, `nil` for a remote
  /// one. Use this for any FileManager work.
  var localWorkingDirectory: URL? { location.localWorkingDirectory }

  /// Whether this is a folder-synthetic worktree.
  var isFolder: Bool { kind == .folder }

  /// Designated initializer: id is derived from the location.
  nonisolated init(
    location: WorktreeLocation,
    kind: RepositoryKind,
    name: String,
    detail: String,
    createdAt: Date? = nil,
    isMissing: Bool = false,
    isAttached: Bool = true
  ) {
    self.location = location
    self.kind = kind
    self.name = name
    self.detail = detail
    self.createdAt = createdAt
    self.isMissing = isMissing
    self.isAttached = isAttached
    self.isMainWorktree = location.isMainWorktree
    self.id = location.id
  }

  /// Back-compat initializer: builds the location from `workingDirectory` +
  /// `repositoryRootURL` + `host`. Kept so existing call sites (and tests)
  /// compile while the model migrates.
  nonisolated init(
    id: WorktreeID,
    kind: RepositoryKind,
    name: String,
    detail: String,
    workingDirectory: URL,
    repositoryRootURL: URL,
    createdAt: Date? = nil,
    isMissing: Bool = false,
    isAttached: Bool = true,
    host: RemoteHost? = nil
  ) {
    if let host {
      // Normalize so a remote path that happens to exist locally as a directory
      // can't bake a disk-state-dependent trailing slash into the stored strings.
      self.location = .remote(
        host,
        workingDirectory: RepositoryLocation.normalizedRemotePath(
          workingDirectory.path(percentEncoded: false)),
        repositoryRoot: RepositoryLocation.normalizedRemotePath(
          repositoryRootURL.path(percentEncoded: false))
      )
    } else {
      self.location = .local(workingDirectory: workingDirectory, repositoryRoot: repositoryRootURL)
    }
    self.kind = kind
    self.name = name
    self.detail = detail
    self.createdAt = createdAt
    self.isMissing = isMissing
    self.isAttached = isAttached
    self.isMainWorktree = location.isMainWorktree
    self.id = id
  }

  /// Copy with a new display name, preserving `location` (and thus host and id)
  /// and every other field, so renaming a remote worktree can't strip its host.
  func renamed(_ newName: String) -> Worktree {
    Worktree(
      location: location,
      kind: kind,
      name: newName,
      detail: detail,
      createdAt: createdAt,
      isMissing: isMissing,
      isAttached: isAttached
    )
  }
}

extension Worktree {
  /// Base environment variables for Supacode scripts (supplemented per-surface).
  var scriptEnvironment: [String: String] {
    [
      "SUPACODE_WORKTREE_PATH": workingDirectory.path(percentEncoded: false),
      "SUPACODE_ROOT_PATH": repositoryRootURL.path(percentEncoded: false),
    ]
  }

}
