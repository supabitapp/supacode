import Foundation

nonisolated struct RepositorySettings: Codable, Equatable, Sendable {
  var repositoryName: String?
  var setupScript: String
  var runScript: String
  var openActionID: String
  var worktreeBaseRef: String?
  var copyIgnoredOnWorktreeCreate: Bool
  var copyUntrackedOnWorktreeCreate: Bool
  var pullRequestMergeStrategy: PullRequestMergeStrategy

  private enum CodingKeys: String, CodingKey {
    case repositoryName
    case setupScript
    case runScript
    case openActionID
    case worktreeBaseRef
    case copyIgnoredOnWorktreeCreate
    case copyUntrackedOnWorktreeCreate
    case pullRequestMergeStrategy
  }

  static let `default` = RepositorySettings(
    repositoryName: nil,
    setupScript: "",
    runScript: "",
    openActionID: OpenWorktreeAction.automaticSettingsID,
    worktreeBaseRef: nil,
    copyIgnoredOnWorktreeCreate: false,
    copyUntrackedOnWorktreeCreate: false,
    pullRequestMergeStrategy: .merge
  )

  init(
    repositoryName: String?,
    setupScript: String,
    runScript: String,
    openActionID: String,
    worktreeBaseRef: String?,
    copyIgnoredOnWorktreeCreate: Bool,
    copyUntrackedOnWorktreeCreate: Bool,
    pullRequestMergeStrategy: PullRequestMergeStrategy
  ) {
    self.repositoryName = repositoryName
    self.setupScript = setupScript
    self.runScript = runScript
    self.openActionID = openActionID
    self.worktreeBaseRef = worktreeBaseRef
    self.copyIgnoredOnWorktreeCreate = copyIgnoredOnWorktreeCreate
    self.copyUntrackedOnWorktreeCreate = copyUntrackedOnWorktreeCreate
    self.pullRequestMergeStrategy = pullRequestMergeStrategy
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    repositoryName =
      try container.decodeIfPresent(String.self, forKey: .repositoryName)
    setupScript =
      try container.decodeIfPresent(String.self, forKey: .setupScript)
      ?? Self.default.setupScript
    runScript =
      try container.decodeIfPresent(String.self, forKey: .runScript)
      ?? Self.default.runScript
    openActionID =
      try container.decodeIfPresent(String.self, forKey: .openActionID)
      ?? Self.default.openActionID
    worktreeBaseRef =
      try container.decodeIfPresent(String.self, forKey: .worktreeBaseRef)
    copyIgnoredOnWorktreeCreate =
      try container.decodeIfPresent(
        Bool.self,
        forKey: .copyIgnoredOnWorktreeCreate
      ) ?? Self.default.copyIgnoredOnWorktreeCreate
    copyUntrackedOnWorktreeCreate =
      try container.decodeIfPresent(
        Bool.self,
        forKey: .copyUntrackedOnWorktreeCreate
      ) ?? Self.default.copyUntrackedOnWorktreeCreate
    pullRequestMergeStrategy =
      try container.decodeIfPresent(
        PullRequestMergeStrategy.self,
        forKey: .pullRequestMergeStrategy
      ) ?? Self.default.pullRequestMergeStrategy
  }
}
