import Foundation

nonisolated struct RepositorySettings: Codable, Equatable, Sendable {
  var setupScript: String
  var archiveScript: String
  var runScript: String
  var openActionID: String
  var worktreeBaseRef: String?
  var worktreeBaseDirectoryPath: String?
  var copyIgnoredOnWorktreeCreate: Bool
  var copyUntrackedOnWorktreeCreate: Bool
  var pullRequestMergeStrategy: PullRequestMergeStrategy

  private enum CodingKeys: String, CodingKey {
    case setupScript
    case archiveScript
    case runScript
    case openActionID
    case worktreeBaseRef
    case worktreeBaseDirectoryPath
    case copyIgnoredOnWorktreeCreate
    case copyUntrackedOnWorktreeCreate
    case pullRequestMergeStrategy
  }

  static let `default` = RepositorySettings(
    setupScript: "",
    archiveScript: "",
    runScript: "",
    openActionID: OpenWorktreeAction.automaticSettingsID,
    worktreeBaseRef: nil,
    worktreeBaseDirectoryPath: nil,
    copyIgnoredOnWorktreeCreate: false,
    copyUntrackedOnWorktreeCreate: false,
    pullRequestMergeStrategy: .merge
  )

  init(
    setupScript: String,
    archiveScript: String,
    runScript: String,
    openActionID: String,
    worktreeBaseRef: String?,
    worktreeBaseDirectoryPath: String? = nil,
    copyIgnoredOnWorktreeCreate: Bool,
    copyUntrackedOnWorktreeCreate: Bool,
    pullRequestMergeStrategy: PullRequestMergeStrategy
  ) {
    self.setupScript = setupScript
    self.archiveScript = archiveScript
    self.runScript = runScript
    self.openActionID = openActionID
    self.worktreeBaseRef = worktreeBaseRef
    self.worktreeBaseDirectoryPath = worktreeBaseDirectoryPath
    self.copyIgnoredOnWorktreeCreate = copyIgnoredOnWorktreeCreate
    self.copyUntrackedOnWorktreeCreate = copyUntrackedOnWorktreeCreate
    self.pullRequestMergeStrategy = pullRequestMergeStrategy
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    setupScript =
      try container.decodeIfPresent(String.self, forKey: .setupScript)
      ?? Self.default.setupScript
    archiveScript =
      try container.decodeIfPresent(String.self, forKey: .archiveScript)
      ?? Self.default.archiveScript
    runScript =
      try container.decodeIfPresent(String.self, forKey: .runScript)
      ?? Self.default.runScript
    openActionID =
      try container.decodeIfPresent(String.self, forKey: .openActionID)
      ?? Self.default.openActionID
    worktreeBaseRef =
      try container.decodeIfPresent(String.self, forKey: .worktreeBaseRef)
    worktreeBaseDirectoryPath =
      try container.decodeIfPresent(String.self, forKey: .worktreeBaseDirectoryPath)
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
