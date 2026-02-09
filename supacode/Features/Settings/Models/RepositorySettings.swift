import Foundation

nonisolated struct RepositorySettings: Codable, Equatable, Sendable {
  var setupScript: String
  var runScript: String
  var openActionID: String
  var worktreeBaseRef: String?
  var copyIgnoredOnWorktreeCreate: Bool
  var copyUntrackedOnWorktreeCreate: Bool
  var pullRequestMergeStrategy: PullRequestMergeStrategy
  var defaultAgentIDs: [String]

  private enum CodingKeys: String, CodingKey {
    case setupScript
    case runScript
    case openActionID
    case worktreeBaseRef
    case copyIgnoredOnWorktreeCreate
    case copyUntrackedOnWorktreeCreate
    case pullRequestMergeStrategy
    case defaultAgentIDs
  }

  static let `default` = RepositorySettings(
    setupScript: "",
    runScript: "",
    openActionID: OpenWorktreeAction.automaticSettingsID,
    worktreeBaseRef: nil,
    copyIgnoredOnWorktreeCreate: false,
    copyUntrackedOnWorktreeCreate: false,
    pullRequestMergeStrategy: .merge,
    defaultAgentIDs: ["claude"]
  )

  init(
    setupScript: String,
    runScript: String,
    openActionID: String,
    worktreeBaseRef: String?,
    copyIgnoredOnWorktreeCreate: Bool,
    copyUntrackedOnWorktreeCreate: Bool,
    pullRequestMergeStrategy: PullRequestMergeStrategy,
    defaultAgentIDs: [String] = ["claude"]
  ) {
    self.setupScript = setupScript
    self.runScript = runScript
    self.openActionID = openActionID
    self.worktreeBaseRef = worktreeBaseRef
    self.copyIgnoredOnWorktreeCreate = copyIgnoredOnWorktreeCreate
    self.copyUntrackedOnWorktreeCreate = copyUntrackedOnWorktreeCreate
    self.pullRequestMergeStrategy = pullRequestMergeStrategy
    self.defaultAgentIDs = defaultAgentIDs
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
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
    defaultAgentIDs =
      try container.decodeIfPresent(
        [String].self,
        forKey: .defaultAgentIDs
      ) ?? Self.default.defaultAgentIDs
  }
}
