import Foundation
import SupacodeSettingsShared

/// Branded identifier for a `Repository`. A thin wrapper over the persisted
/// string id so a repository id can never be passed where a worktree id (or a
/// bare path) is expected. Encodes as a single string, so `OrderedDictionary`
/// keys and `sidebar.json` keep their existing on-disk shape.
nonisolated struct RepositoryID: Hashable, Sendable, Codable, CustomStringConvertible {
  let rawValue: String

  init(_ rawValue: String) { self.rawValue = rawValue }

  var description: String { rawValue }

  init(from decoder: any Decoder) throws {
    self.rawValue = try decoder.singleValueContainer().decode(String.self)
  }
  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// Branded identifier for a `Worktree` (and the sidebar row keyed off it).
/// Same string-backed shape as `RepositoryID`; the two are compiler-distinct so
/// a repo id and a worktree id can't be confused at a call site.
nonisolated struct WorktreeID: Hashable, Sendable, Codable, CustomStringConvertible {
  let rawValue: String

  init(_ rawValue: String) { self.rawValue = rawValue }

  var description: String { rawValue }

  init(from decoder: any Decoder) throws {
    self.rawValue = try decoder.singleValueContainer().decode(String.self)
  }
  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// Whether a repository (and its worktrees) is a real git repo or a plain
/// directory tracked as a folder. Replaces the standalone `isGitRepository`
/// flag so git-vs-folder is one explicit value rather than a bool that can
/// drift from the rest of the model.
nonisolated enum RepositoryKind: Hashable, Sendable {
  case git
  case folder
}

/// Where a repository physically lives. The single home for the local-vs-remote
/// distinction: a local repo carries a real filesystem `URL`, a remote repo
/// carries its `RemoteHost` plus an absolute path string. There is no way to
/// pull a local `URL` out of a remote location (`localRootURL` is `nil`), so a
/// FileManager call can never be aimed at a remote path by accident.
nonisolated enum RepositoryLocation: Hashable, Sendable {
  case local(URL)
  case remote(RemoteHost, path: String)

  var host: RemoteHost? {
    switch self {
    case .local: nil
    case .remote(let host, _): host
    }
  }

  /// The filesystem URL for a local repo, `nil` for a remote one. Use this for
  /// any FileManager / on-disk work so remote paths are structurally excluded.
  var localRootURL: URL? {
    switch self {
    case .local(let url): url
    case .remote: nil
    }
  }

  /// A URL suitable only for display and for the `@Shared(.repositorySettings)`
  /// key. For a remote repo this is a synthetic `file://` URL over the remote
  /// path; never hand it to FileManager (use `localRootURL`).
  var displayURL: URL {
    switch self {
    case .local(let url): url
    case .remote(_, let path): URL(fileURLWithPath: path)
    }
  }

  var path: String {
    switch self {
    case .local(let url): url.path(percentEncoded: false)
    case .remote(_, let path): path
    }
  }

  /// The branded id derived from the location. Local repos keep their bare
  /// absolute path (preserving persisted ids); remote repos use the
  /// unambiguous `remote://<user@host:port><absolutePath>` scheme.
  var id: RepositoryID {
    switch self {
    case .local(let url): RepositoryID(url.path(percentEncoded: false))
    case .remote(let host, let path): RepositoryID("remote://" + host.authority + path)
    }
  }
}

/// Where a worktree physically lives. Carries both the worktree's working
/// directory and its repository root, bound to a single host, so a worktree
/// can never mix a local working dir with a remote root (or two hosts). Mirrors
/// `RepositoryLocation`'s `local*` accessors for the same FileManager safety.
nonisolated enum WorktreeLocation: Hashable, Sendable {
  case local(workingDirectory: URL, repositoryRoot: URL)
  case remote(RemoteHost, workingDirectory: String, repositoryRoot: String)

  var host: RemoteHost? {
    switch self {
    case .local: nil
    case .remote(let host, _, _): host
    }
  }

  /// The working directory as a filesystem URL for a local worktree, `nil` for
  /// a remote one.
  var localWorkingDirectory: URL? {
    switch self {
    case .local(let workingDirectory, _): workingDirectory
    case .remote: nil
    }
  }

  /// Display / env-var URL for the working directory. Synthetic `file://` for
  /// remote; never hand to FileManager.
  var workingDirectory: URL {
    switch self {
    case .local(let workingDirectory, _): workingDirectory
    case .remote(_, let workingDirectory, _): URL(fileURLWithPath: workingDirectory)
    }
  }

  var repositoryRootURL: URL {
    switch self {
    case .local(_, let repositoryRoot): repositoryRoot
    case .remote(_, _, let repositoryRoot): URL(fileURLWithPath: repositoryRoot)
    }
  }

  var workingDirectoryPath: String {
    switch self {
    case .local(let workingDirectory, _): workingDirectory.path(percentEncoded: false)
    case .remote(_, let workingDirectory, _): workingDirectory
    }
  }

  /// The owning repository's location (same host, repository-root path).
  var repositoryLocation: RepositoryLocation {
    switch self {
    case .local(_, let repositoryRoot): .local(repositoryRoot)
    case .remote(let host, _, let repositoryRoot): .remote(host, path: repositoryRoot)
    }
  }

  /// The branded worktree id derived from the location and kind. Folder
  /// synthetics derive from the owning repo id (so the row round-trips to its
  /// repository); git worktrees brand their working directory.
  func id(kind: RepositoryKind) -> WorktreeID {
    if kind == .folder {
      return WorktreeID.folder(repositoryID: repositoryLocation.id)
    }
    switch self {
    case .local(let workingDirectory, _):
      return WorktreeID(workingDirectory.path(percentEncoded: false))
    case .remote(let host, let workingDirectory, _):
      return WorktreeID("remote://" + host.authority + workingDirectory)
    }
  }
}

nonisolated extension WorktreeID {
  /// Folder-synthetic worktree id: the `folder:` marker composed with the
  /// owning repository's id. Composes with the `remote://` scheme for remote
  /// folders, so `folder:` is the single git-vs-folder discriminator at the id
  /// level for both local and remote.
  static let folderPrefix = "folder:"

  static func folder(repositoryID: RepositoryID) -> WorktreeID {
    WorktreeID(folderPrefix + repositoryID.rawValue)
  }

  /// Whether this is a folder-synthetic worktree id.
  var isFolder: Bool { rawValue.hasPrefix(Self.folderPrefix) }

  /// The owning `RepositoryID` recovered from a folder-synthetic id, or `nil`
  /// when this isn't a folder id (a git worktree id doesn't round-trip to its
  /// repo by string transform; callers locate it by scanning state).
  var folderRepositoryID: RepositoryID? {
    guard isFolder else { return nil }
    return RepositoryID(String(rawValue.dropFirst(Self.folderPrefix.count)))
  }
}
