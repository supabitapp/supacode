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
  /// Prefix for the synthetic id a worktree carries while it is being created.
  static let pendingPrefix = "pending:"

  let rawValue: String

  init(_ rawValue: String) { self.rawValue = rawValue }

  var description: String { rawValue }

  /// A placeholder id for an in-flight creation, not yet a real worktree.
  var isPending: Bool { rawValue.hasPrefix(Self.pendingPrefix) }

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
  /// absolute path; remote repos use the self-descriptive
  /// `<user@host:port><absolutePath>` form. The two never collide: a local id
  /// is always an absolute path (leading `/`), a remote authority never starts
  /// with `/`.
  var id: RepositoryID {
    switch self {
    case .local(let url): RepositoryID(url.path(percentEncoded: false))
    case .remote(let host, let path): RepositoryID(host.authority + path)
    }
  }

  /// Trailing-slash-trimmed remote path, kept stable so a cosmetic edit doesn't
  /// churn the derived id.
  static func normalizedRemotePath(_ path: String) -> String {
    var trimmed = Substring(path.trimmingCharacters(in: .whitespaces))
    while trimmed.count > 1, trimmed.hasSuffix("/") {
      trimmed = trimmed.dropLast()
    }
    return String(trimmed)
  }

  /// Parse a persisted repository id back into a location. A leading `/` is a
  /// local absolute path; anything else is a remote `[user@]host[:port]<path>`
  /// authority. Returns `nil` for a remote id whose authority can't be parsed.
  static func parse(persistedID: String) -> RepositoryLocation? {
    if persistedID.hasPrefix("/") {
      return .local(URL(fileURLWithPath: persistedID))
    }
    guard let slash = persistedID.firstIndex(of: "/") else { return nil }
    let authority = String(persistedID[..<slash])
    let path = String(persistedID[slash...])
    guard let host = RemoteHost(authority: authority) else { return nil }
    return .remote(host, path: path)
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

  /// The branded worktree id derived from the location. Independent of
  /// git-vs-folder: a folder synthetic and a git main worktree at the same path
  /// share the id (they're mutually exclusive per path at any moment), and
  /// `Worktree.kind` carries the runtime classification.
  var id: WorktreeID {
    switch self {
    case .local(let workingDirectory, _):
      return WorktreeID(workingDirectory.path(percentEncoded: false))
    case .remote(let host, let workingDirectory, _):
      return WorktreeID(host.authority + workingDirectory)
    }
  }
}
