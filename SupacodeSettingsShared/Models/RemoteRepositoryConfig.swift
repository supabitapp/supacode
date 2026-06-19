import Foundation

/// A user-configured remote repository/folder reachable over SSH. Persisted in
/// `GlobalSettings.remoteRepositories` (mirrors `globalScripts`); each entry is
/// materialized at load time into a folder-kind `Repository` whose synthetic
/// worktree carries `host`, so its terminal launches via
/// `ssh -tt <host> zmx attach …` (see Phase A).
///
/// `remotePath` is an absolute path on the remote host, resolved (and any
/// leading `~` expanded) over ssh at creation time. `displayName` is the
/// sidebar title.
public nonisolated struct RemoteRepositoryConfig: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var host: RemoteHost
  public var remotePath: String
  public var displayName: String

  public init(
    id: UUID = UUID(),
    host: RemoteHost,
    remotePath: String,
    displayName: String
  ) {
    self.id = id
    self.host = host
    self.remotePath = remotePath
    self.displayName = displayName
  }

  /// Trailing-slash-trimmed remote path. Kept stable so the derived
  /// repository / worktree id doesn't churn on a cosmetic edit.
  public var normalizedRemotePath: String {
    var trimmed = Substring(remotePath.trimmingCharacters(in: .whitespaces))
    while trimmed.count > 1, trimmed.hasSuffix("/") {
      trimmed = trimmed.dropLast()
    }
    return String(trimmed)
  }

  /// Sidebar title, falling back to the remote path's last component when the
  /// user left the name blank.
  public var resolvedDisplayName: String {
    let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { return trimmed }
    let leaf = normalizedRemotePath.split(separator: "/").last.map(String.init)
    return leaf?.isEmpty == false ? leaf! : host.alias
  }
}
