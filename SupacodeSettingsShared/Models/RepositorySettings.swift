import Foundation

public nonisolated struct RepositorySettings: Codable, Equatable, Sendable {
  public var setupScript: String
  public var archiveScript: String
  public var deleteScript: String
  /// Runs when a File Explorer file is opened, with its path in `SUPACODE_FILE_PATH`. Empty
  /// inherits the global script, then the system default app. A hook, never in the script menu.
  public var openFileScript: String
  /// Legacy field kept for backward-compatible JSON serialization.
  /// New code should use `scripts` instead. On encode, this is
  /// derived from the first `.run`-kind script's command.
  public private(set) var runScript: String
  public var scripts: [ScriptDefinition]
  public var openActionID: String
  public var worktreeBaseRef: String?
  public var worktreeBaseDirectoryPath: String?
  public var copyIgnoredOnWorktreeCreate: Bool?
  public var copyUntrackedOnWorktreeCreate: Bool?
  public var pullRequestMergeStrategy: PullRequestMergeStrategy?
  /// Action when a worktree's pull request is merged. `nil` inherits the global setting.
  public var mergedWorktreeAction: MergedWorktreeAction?

  private enum CodingKeys: String, CodingKey {
    case setupScript
    case archiveScript
    case deleteScript
    case openFileScript
    case runScript
    case scripts
    case openActionID
    case worktreeBaseRef
    case worktreeBaseDirectoryPath
    case copyIgnoredOnWorktreeCreate
    case copyUntrackedOnWorktreeCreate
    case pullRequestMergeStrategy
    case mergedWorktreeAction
  }

  public static let `default` = RepositorySettings(
    setupScript: "",
    archiveScript: "",
    deleteScript: "",
    openFileScript: "",
    runScript: "",
    scripts: [],
    openActionID: OpenWorktreeAction.automaticSettingsID,
    worktreeBaseRef: nil,
    worktreeBaseDirectoryPath: nil,
    copyIgnoredOnWorktreeCreate: nil,
    copyUntrackedOnWorktreeCreate: nil,
    pullRequestMergeStrategy: nil,
    mergedWorktreeAction: nil,
  )

  public init(
    setupScript: String,
    archiveScript: String,
    deleteScript: String,
    openFileScript: String = "",
    runScript: String,
    scripts: [ScriptDefinition] = [],
    openActionID: String,
    worktreeBaseRef: String?,
    worktreeBaseDirectoryPath: String? = nil,
    copyIgnoredOnWorktreeCreate: Bool? = nil,
    copyUntrackedOnWorktreeCreate: Bool? = nil,
    pullRequestMergeStrategy: PullRequestMergeStrategy? = nil,
    mergedWorktreeAction: MergedWorktreeAction? = nil
  ) {
    self.setupScript = setupScript
    self.archiveScript = archiveScript
    self.deleteScript = deleteScript
    self.openFileScript = openFileScript
    self.runScript = runScript
    self.scripts = scripts
    self.openActionID = openActionID
    self.worktreeBaseRef = worktreeBaseRef
    self.worktreeBaseDirectoryPath = worktreeBaseDirectoryPath
    self.copyIgnoredOnWorktreeCreate = copyIgnoredOnWorktreeCreate
    self.copyUntrackedOnWorktreeCreate = copyUntrackedOnWorktreeCreate
    self.pullRequestMergeStrategy = pullRequestMergeStrategy
    self.mergedWorktreeAction = mergedWorktreeAction
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
    openFileScript =
      try container.decodeIfPresent(String.self, forKey: .openFileScript)
      ?? Self.default.openFileScript
    runScript =
      try container.decodeIfPresent(String.self, forKey: .runScript)
      ?? Self.default.runScript
    // Missing `scripts` triggers legacy `runScript` migration; corrupt array is `[]`.
    let decodedScripts: [ScriptDefinition]? = container.decodeLossyArrayIfPresent(forKey: .scripts)
    if let decodedScripts {
      scripts = decodedScripts
    } else if !runScript.isEmpty {
      scripts = [ScriptDefinition(kind: .run, command: runScript)]
    } else {
      scripts = Self.default.scripts
    }
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
    mergedWorktreeAction =
      try container.decodeIfPresent(MergedWorktreeAction.self, forKey: .mergedWorktreeAction)
      ?? Self.default.mergedWorktreeAction
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(setupScript, forKey: .setupScript)
    try container.encode(archiveScript, forKey: .archiveScript)
    try container.encode(deleteScript, forKey: .deleteScript)
    try container.encode(openFileScript, forKey: .openFileScript)
    // Derive `runScript` from the first `.run`-kind script's command
    // so older clients can still read the value.
    // Fall back to empty string (not the legacy `runScript` property)
    // so removing all `.run` scripts correctly signals removal to
    // older clients instead of leaking the stale legacy value.
    let derivedRunScript = scripts.first(where: { $0.kind == .run })?.command ?? ""
    try container.encode(derivedRunScript, forKey: .runScript)
    try container.encode(scripts, forKey: .scripts)
    try container.encode(openActionID, forKey: .openActionID)
    try container.encodeIfPresent(worktreeBaseRef, forKey: .worktreeBaseRef)
    try container.encodeIfPresent(worktreeBaseDirectoryPath, forKey: .worktreeBaseDirectoryPath)
    try container.encodeIfPresent(copyIgnoredOnWorktreeCreate, forKey: .copyIgnoredOnWorktreeCreate)
    try container.encodeIfPresent(copyUntrackedOnWorktreeCreate, forKey: .copyUntrackedOnWorktreeCreate)
    try container.encodeIfPresent(pullRequestMergeStrategy, forKey: .pullRequestMergeStrategy)
    try container.encodeIfPresent(mergedWorktreeAction, forKey: .mergedWorktreeAction)
  }
}
