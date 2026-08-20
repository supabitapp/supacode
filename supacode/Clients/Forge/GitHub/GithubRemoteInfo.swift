import Foundation

struct GithubRemoteInfo: Equatable, Sendable {
  let host: String
  let owner: String
  let repo: String
}

extension GithubRemoteInfo {
  /// Takes the leading owner/repo segments on a GitHub-looking host.
  nonisolated init?(gitRemote: GitRemote) {
    guard gitRemote.host.contains("github"),
      gitRemote.pathComponents.count >= 2,
      let owner = gitRemote.pathComponents.first,
      !owner.isEmpty
    else {
      return nil
    }
    let repo = gitRemote.pathComponents[1]
    guard !repo.isEmpty else {
      return nil
    }
    self.init(host: gitRemote.host, owner: owner, repo: repo)
  }
}
