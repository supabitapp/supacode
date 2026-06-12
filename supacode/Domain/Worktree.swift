import Foundation
import SupacodeSettingsShared

nonisolated struct Worktree: Identifiable, Hashable, Sendable {
  /// Branded id derived from the location and kind (local git: working-dir
  /// path; local folder: `folder:<repoID>`; remote: `remote://…`). Stored so
  /// legacy/test call sites can pass it explicitly; production derives it.
  let id: WorktreeID
  /// Where the worktree lives. Single source of truth for `host`,
  /// `workingDirectory`, `repositoryRootURL`, and the FileManager-safe
  /// `localWorkingDirectory`.
  let location: WorktreeLocation
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

  /// SSH host this worktree lives on, or `nil` for a local worktree.
  var host: RemoteHost? { location.host }

  /// Display / env-var working-directory URL. For a remote worktree this is a
  /// synthetic `file://` over the remote path; never hand it to FileManager.
  var workingDirectory: URL { location.workingDirectory }
  var repositoryRootURL: URL { location.repositoryRootURL }

  /// The on-disk working directory for a local worktree, `nil` for a remote
  /// one. Use this for any FileManager work.
  var localWorkingDirectory: URL? { location.localWorkingDirectory }

  /// Whether this is a folder-synthetic worktree (derived from the id).
  var isFolder: Bool { id.isFolder }

  /// Designated initializer: id is derived from the location and kind.
  nonisolated init(
    location: WorktreeLocation,
    kind: RepositoryKind = .git,
    name: String,
    detail: String,
    createdAt: Date? = nil,
    isMissing: Bool = false,
    isAttached: Bool = true
  ) {
    self.location = location
    self.name = name
    self.detail = detail
    self.createdAt = createdAt
    self.isMissing = isMissing
    self.isAttached = isAttached
    self.id = location.id(kind: kind)
  }

  /// Back-compat initializer: builds the location from `workingDirectory` +
  /// `repositoryRootURL` + `host`. Kept so existing call sites (and tests)
  /// compile while the model migrates.
  nonisolated init(
    id: WorktreeID,
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
      self.location = .remote(
        host,
        workingDirectory: workingDirectory.path(percentEncoded: false),
        repositoryRoot: repositoryRootURL.path(percentEncoded: false)
      )
    } else {
      self.location = .local(workingDirectory: workingDirectory, repositoryRoot: repositoryRootURL)
    }
    self.name = name
    self.detail = detail
    self.createdAt = createdAt
    self.isMissing = isMissing
    self.isAttached = isAttached
    self.id = id
  }

  /// Copy with a new display name, preserving `location` (and thus host and id)
  /// and every other field, so renaming a remote worktree can't strip its host.
  func renamed(_ newName: String) -> Worktree {
    Worktree(
      location: location,
      kind: id.isFolder ? .folder : .git,
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
