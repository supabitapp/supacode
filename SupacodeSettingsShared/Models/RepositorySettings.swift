import Foundation

public nonisolated struct RepositorySettings: Codable, Equatable, Sendable {
  public var setupScript: String
  public var archiveScript: String
  public var deleteScript: String
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

  private enum CodingKeys: String, CodingKey {
    case setupScript
    case archiveScript
    case deleteScript
    case runScript
    case scripts
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
    openActionID: OpenWorktreeAction.automaticSettingsID,
    worktreeBaseRef: nil,
    worktreeBaseDirectoryPath: nil,
    copyIgnoredOnWorktreeCreate: nil,
    copyUntrackedOnWorktreeCreate: nil,
    pullRequestMergeStrategy: nil,
  )

  public init(
    setupScript: String,
    archiveScript: String,
    deleteScript: String,
    runScript: String,
    scripts: [ScriptDefinition] = [],
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
    // Decode element-by-element so a single unknown `ScriptKind`
    // only drops that entry, not the entire array.
    let decodedScripts = Self.decodeScriptsLossily(from: container)
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
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(setupScript, forKey: .setupScript)
    try container.encode(archiveScript, forKey: .archiveScript)
    try container.encode(deleteScript, forKey: .deleteScript)
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
  }

  /// Decodes the `scripts` array element-by-element, silently
  /// skipping entries that fail (e.g. unknown `ScriptKind`).
  /// Returns `nil` when the key is absent (legacy JSON), or `[]`
  /// when the key is present but corrupted (e.g. `null`).
  private static func decodeScriptsLossily(
    from container: KeyedDecodingContainer<CodingKeys>
  ) -> [ScriptDefinition]? {
    guard container.contains(.scripts) else { return nil }
    guard let wrappers = try? container.decode([Lossy<ScriptDefinition>].self, forKey: .scripts) else {
      // Key exists but value is not a valid array (e.g. null or
      // wrong type). Return empty rather than triggering legacy
      // migration which would overwrite with stale data.
      return []
    }
    return wrappers.compactMap { $0.value }
  }
}

/// Wrapper that always succeeds at the container level,
/// capturing decode failures as `nil` instead of throwing.
private nonisolated struct Lossy<T: Decodable & Sendable>: Decodable, Sendable {
  nonisolated let value: T?
  nonisolated init(from decoder: Decoder) throws {
    value = try? T(from: decoder)
  }
}
