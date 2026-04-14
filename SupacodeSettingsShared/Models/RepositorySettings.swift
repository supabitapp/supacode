import Foundation

public nonisolated struct RepositorySettings: Codable, Equatable, Sendable {
  public var setupScript: String
  public var archiveScript: String
  public var deleteScript: String
  public var runScript: String
  public var scripts: [ScriptDefinition]
  public var selectedScriptID: UUID?
  public var openActionID: String
  public var worktreeBaseRef: String?
  public var worktreeBaseDirectoryPath: String?
  public var copyIgnoredOnWorktreeCreate: Bool?
  public var copyUntrackedOnWorktreeCreate: Bool?
  public var pullRequestMergeStrategy: PullRequestMergeStrategy?

  private enum CodingKeys: String, CodingKey {
    case setupScript
    case archiveScript
    case deleteScript
    case runScript
    case scripts
    case selectedScriptID
    case openActionID
    case worktreeBaseRef
    case worktreeBaseDirectoryPath
    case copyIgnoredOnWorktreeCreate
    case copyUntrackedOnWorktreeCreate
    case pullRequestMergeStrategy
  }

  public static let `default` = RepositorySettings(
    setupScript: "",
    archiveScript: "",
    deleteScript: "",
    runScript: "",
    scripts: [],
    selectedScriptID: nil,
    openActionID: OpenWorktreeAction.automaticSettingsID,
    worktreeBaseRef: nil,
    worktreeBaseDirectoryPath: nil,
    copyIgnoredOnWorktreeCreate: nil,
    copyUntrackedOnWorktreeCreate: nil,
    pullRequestMergeStrategy: nil
  )

  public init(
    setupScript: String,
    archiveScript: String,
    deleteScript: String,
    runScript: String,
    scripts: [ScriptDefinition] = [],
    selectedScriptID: UUID? = nil,
    openActionID: String,
    worktreeBaseRef: String?,
    worktreeBaseDirectoryPath: String? = nil,
    copyIgnoredOnWorktreeCreate: Bool? = nil,
    copyUntrackedOnWorktreeCreate: Bool? = nil,
    pullRequestMergeStrategy: PullRequestMergeStrategy? = nil
  ) {
    self.setupScript = setupScript
    self.archiveScript = archiveScript
    self.deleteScript = deleteScript
    self.runScript = runScript
    self.scripts = scripts
    self.selectedScriptID = selectedScriptID
    self.openActionID = openActionID
    self.worktreeBaseRef = worktreeBaseRef
    self.worktreeBaseDirectoryPath = worktreeBaseDirectoryPath
    self.copyIgnoredOnWorktreeCreate = copyIgnoredOnWorktreeCreate
    self.copyUntrackedOnWorktreeCreate = copyUntrackedOnWorktreeCreate
    self.pullRequestMergeStrategy = pullRequestMergeStrategy
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    setupScript =
      try container.decodeIfPresent(String.self, forKey: .setupScript)
      ?? Self.default.setupScript
    archiveScript =
      try container.decodeIfPresent(String.self, forKey: .archiveScript)
      ?? Self.default.archiveScript
    deleteScript =
      try container.decodeIfPresent(String.self, forKey: .deleteScript)
      ?? Self.default.deleteScript
    runScript =
      try container.decodeIfPresent(String.self, forKey: .runScript)
      ?? Self.default.runScript
    // Migrate legacy `runScript` into the new `scripts` array when
    // the `scripts` key is absent from persisted JSON.
    let decodedScripts = try container.decodeIfPresent([ScriptDefinition].self, forKey: .scripts)
    if let decodedScripts {
      scripts = decodedScripts
    } else if !runScript.isEmpty {
      scripts = [ScriptDefinition(kind: .run, command: runScript)]
    } else {
      scripts = Self.default.scripts
    }
    selectedScriptID =
      try container.decodeIfPresent(UUID.self, forKey: .selectedScriptID)
      ?? Self.default.selectedScriptID
    openActionID =
      try container.decodeIfPresent(String.self, forKey: .openActionID)
      ?? Self.default.openActionID
    worktreeBaseRef =
      try container.decodeIfPresent(String.self, forKey: .worktreeBaseRef)
    worktreeBaseDirectoryPath =
      try container.decodeIfPresent(String.self, forKey: .worktreeBaseDirectoryPath)
    copyIgnoredOnWorktreeCreate =
      try container.decodeIfPresent(Bool.self, forKey: .copyIgnoredOnWorktreeCreate)
      ?? Self.default.copyIgnoredOnWorktreeCreate
    copyUntrackedOnWorktreeCreate =
      try container.decodeIfPresent(Bool.self, forKey: .copyUntrackedOnWorktreeCreate)
      ?? Self.default.copyUntrackedOnWorktreeCreate
    pullRequestMergeStrategy =
      try container.decodeIfPresent(PullRequestMergeStrategy.self, forKey: .pullRequestMergeStrategy)
      ?? Self.default.pullRequestMergeStrategy
  }
}
