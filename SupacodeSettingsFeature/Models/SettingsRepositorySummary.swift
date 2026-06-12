import Foundation
import SupacodeSettingsShared

public struct SettingsRepositorySummary: Equatable, Hashable, Sendable {
  public var id: String
  public var name: String
  public var isGitRepository: Bool
  /// The SSH host the repository lives on, `nil` for local. Carried (rather than
  /// a bare bool) so the per-repo settings key can brand remote repos by host.
  public var host: RemoteHost?
  /// The repository's real root URL, used to key its per-repo settings. For a
  /// local repo this equals `URL(fileURLWithPath: id)`; for a remote repo `id`
  /// is a `remote:` key (not a path), so the bare remote path must be passed in
  /// explicitly so the settings key matches the worktree's `repositoryRootURL`.
  public var rootURL: URL

  /// Lives on an SSH host. Partitions the settings sidebar into Local / Remote.
  public var isRemote: Bool { host != nil }

  public init(
    id: String,
    name: String,
    isGitRepository: Bool = true,
    host: RemoteHost? = nil,
    rootURL: URL? = nil
  ) {
    self.id = id
    self.name = name
    self.isGitRepository = isGitRepository
    self.host = host
    self.rootURL = (rootURL ?? URL(fileURLWithPath: id)).standardizedFileURL
  }
}
