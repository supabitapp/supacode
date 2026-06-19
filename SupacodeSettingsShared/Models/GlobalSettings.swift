public nonisolated enum AutoDeletePeriod: Int, Codable, CaseIterable, Comparable, Sendable {
  #if DEBUG
    case immediately = 0
  #endif
  case oneDay = 1
  case threeDays = 3
  case sevenDays = 7
  case fourteenDays = 14
  case thirtyDays = 30

  public var label: String {
    switch self {
    #if DEBUG
      case .immediately: "Immediately (debug)"
    #endif
    case .oneDay: "After 1 day"
    case .threeDays: "After 3 days"
    case .sevenDays: "After 7 days"
    case .fourteenDays: "After 14 days"
    case .thirtyDays: "After 30 days"
    }
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

public nonisolated struct GlobalSettings: Codable, Equatable, Sendable {
  public var appearanceMode: AppearanceMode
  public var defaultEditorID: String
  public var updateChannel: UpdateChannel
  public var updatesAutomaticallyCheckForUpdates: Bool
  public var updatesAutomaticallyDownloadUpdates: Bool
  public var inAppNotificationsEnabled: Bool
  public var notificationSoundEnabled: Bool
  public var systemNotificationsEnabled: Bool
  public var moveNotifiedWorktreeToTop: Bool
  public var analyticsEnabled: Bool
  public var crashReportsEnabled: Bool
  public var githubIntegrationEnabled: Bool
  public var deleteBranchOnDeleteWorktree: Bool
  public var mergedWorktreeAction: MergedWorktreeAction?
  public var promptForWorktreeCreation: Bool
  public var fetchOriginBeforeWorktreeCreation: Bool
  public var defaultWorktreeBaseDirectoryPath: String?
  public var copyIgnoredOnWorktreeCreate: Bool
  public var copyUntrackedOnWorktreeCreate: Bool
  public var pullRequestMergeStrategy: PullRequestMergeStrategy
  public var terminalThemeSyncEnabled: Bool
  public var hideSingleTabBar: Bool
  public var automatedActionPolicy: AutomatedActionPolicy
  public var autoDeleteArchivedWorktreesAfterDays: AutoDeletePeriod?
  public var shortcutOverrides: [AppShortcutID: AppShortcutOverride]
  /// Scripts shared across every repository. Always `.custom` kind.
  public var globalScripts: [ScriptDefinition]
  /// User-configured remote repositories reachable over SSH. Materialized at
  /// load into folder-kind repositories whose terminals run on the remote host.
  public var remoteRepositories: [RemoteRepositoryConfig]
  public var richAgentNotificationsEnabled: Bool
  public var agentPresenceBadgesEnabled: Bool
  /// When true, an agent integration that reports `.outdated` at launch /
  /// scene activation is silently re-installed so a Supacode update never
  /// strands stale hooks (e.g. legacy `Notification` / `PostToolUseFailure`
  /// entries from earlier wire-protocol revisions).
  public var autoUpdateAgentIntegrationsEnabled: Bool
  public var confirmQuitMode: ConfirmQuitMode
  /// When true, quitting Supacode also closes every terminal tab and tears
  /// down the bundled zmx daemon's sessions, so nothing keeps running in
  /// the background. Default off because persistence is the headline feature.
  public var terminateSessionsOnQuit: Bool

  public static let `default` = GlobalSettings(
    appearanceMode: .dark,
    defaultEditorID: OpenWorktreeAction.automaticSettingsID,
    updateChannel: .stable,
    updatesAutomaticallyCheckForUpdates: true,
    updatesAutomaticallyDownloadUpdates: false,
    inAppNotificationsEnabled: true,
    notificationSoundEnabled: true,
    systemNotificationsEnabled: false,
    moveNotifiedWorktreeToTop: true,
    analyticsEnabled: true,
    crashReportsEnabled: true,
    githubIntegrationEnabled: true,
    deleteBranchOnDeleteWorktree: true,
    mergedWorktreeAction: nil,
    promptForWorktreeCreation: true,
    fetchOriginBeforeWorktreeCreation: true,
    copyIgnoredOnWorktreeCreate: false,
    copyUntrackedOnWorktreeCreate: false,
    pullRequestMergeStrategy: .merge,
    terminalThemeSyncEnabled: true,
    hideSingleTabBar: false,
    automatedActionPolicy: .cliOnly,
    defaultWorktreeBaseDirectoryPath: nil,
    autoDeleteArchivedWorktreesAfterDays: nil,
    shortcutOverrides: [:],
    globalScripts: [],
    remoteRepositories: [],
    richAgentNotificationsEnabled: true,
    agentPresenceBadgesEnabled: true,
    autoUpdateAgentIntegrationsEnabled: true,
    confirmQuitMode: .auto,
    terminateSessionsOnQuit: false
  )

  public init(
    appearanceMode: AppearanceMode,
    defaultEditorID: String,
    updateChannel: UpdateChannel,
    updatesAutomaticallyCheckForUpdates: Bool,
    updatesAutomaticallyDownloadUpdates: Bool,
    inAppNotificationsEnabled: Bool,
    notificationSoundEnabled: Bool,
    systemNotificationsEnabled: Bool = false,
    moveNotifiedWorktreeToTop: Bool,
    analyticsEnabled: Bool,
    crashReportsEnabled: Bool,
    githubIntegrationEnabled: Bool,
    deleteBranchOnDeleteWorktree: Bool,
    mergedWorktreeAction: MergedWorktreeAction? = nil,
    promptForWorktreeCreation: Bool,
    fetchOriginBeforeWorktreeCreation: Bool = true,
    copyIgnoredOnWorktreeCreate: Bool = false,
    copyUntrackedOnWorktreeCreate: Bool = false,
    pullRequestMergeStrategy: PullRequestMergeStrategy = .merge,
    terminalThemeSyncEnabled: Bool = true,
    hideSingleTabBar: Bool = false,
    automatedActionPolicy: AutomatedActionPolicy = .cliOnly,
    defaultWorktreeBaseDirectoryPath: String? = nil,
    autoDeleteArchivedWorktreesAfterDays: AutoDeletePeriod? = nil,
    shortcutOverrides: [AppShortcutID: AppShortcutOverride] = [:],
    globalScripts: [ScriptDefinition] = [],
    remoteRepositories: [RemoteRepositoryConfig] = [],
    richAgentNotificationsEnabled: Bool = true,
    agentPresenceBadgesEnabled: Bool = true,
    autoUpdateAgentIntegrationsEnabled: Bool = true,
    confirmQuitMode: ConfirmQuitMode = .auto,
    terminateSessionsOnQuit: Bool = false
  ) {
    self.appearanceMode = appearanceMode
    self.defaultEditorID = defaultEditorID
    self.updateChannel = updateChannel
    self.updatesAutomaticallyCheckForUpdates = updatesAutomaticallyCheckForUpdates
    self.updatesAutomaticallyDownloadUpdates = updatesAutomaticallyDownloadUpdates
    self.inAppNotificationsEnabled = inAppNotificationsEnabled
    self.notificationSoundEnabled = notificationSoundEnabled
    self.systemNotificationsEnabled = systemNotificationsEnabled
    self.moveNotifiedWorktreeToTop = moveNotifiedWorktreeToTop
    self.analyticsEnabled = analyticsEnabled
    self.crashReportsEnabled = crashReportsEnabled
    self.githubIntegrationEnabled = githubIntegrationEnabled
    self.deleteBranchOnDeleteWorktree = deleteBranchOnDeleteWorktree
    self.mergedWorktreeAction = mergedWorktreeAction
    self.promptForWorktreeCreation = promptForWorktreeCreation
    self.fetchOriginBeforeWorktreeCreation = fetchOriginBeforeWorktreeCreation
    self.copyIgnoredOnWorktreeCreate = copyIgnoredOnWorktreeCreate
    self.copyUntrackedOnWorktreeCreate = copyUntrackedOnWorktreeCreate
    self.pullRequestMergeStrategy = pullRequestMergeStrategy
    self.terminalThemeSyncEnabled = terminalThemeSyncEnabled
    self.hideSingleTabBar = hideSingleTabBar
    self.automatedActionPolicy = automatedActionPolicy
    self.defaultWorktreeBaseDirectoryPath = defaultWorktreeBaseDirectoryPath
    self.autoDeleteArchivedWorktreesAfterDays = autoDeleteArchivedWorktreesAfterDays
    self.shortcutOverrides = shortcutOverrides
    self.globalScripts = globalScripts
    self.remoteRepositories = remoteRepositories
    self.richAgentNotificationsEnabled = richAgentNotificationsEnabled
    self.agentPresenceBadgesEnabled = agentPresenceBadgesEnabled
    self.autoUpdateAgentIntegrationsEnabled = autoUpdateAgentIntegrationsEnabled
    self.confirmQuitMode = confirmQuitMode
    self.terminateSessionsOnQuit = terminateSessionsOnQuit
  }

  /// Keys for reading renamed settings fields that no longer
  /// match the auto-synthesized CodingKeys.
  private struct LegacyCodingKey: CodingKey {
    var stringValue: String
    init?(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { nil }
  }

  // swiftlint:disable:next function_body_length
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let legacy = try decoder.container(keyedBy: LegacyCodingKey.self)
    appearanceMode = try container.decode(AppearanceMode.self, forKey: .appearanceMode)
    defaultEditorID =
      try container.decodeIfPresent(String.self, forKey: .defaultEditorID)
      ?? Self.default.defaultEditorID
    updateChannel =
      try container.decodeIfPresent(UpdateChannel.self, forKey: .updateChannel)
      ?? Self.default.updateChannel
    updatesAutomaticallyCheckForUpdates = try container.decode(Bool.self, forKey: .updatesAutomaticallyCheckForUpdates)
    updatesAutomaticallyDownloadUpdates = try container.decode(Bool.self, forKey: .updatesAutomaticallyDownloadUpdates)
    inAppNotificationsEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .inAppNotificationsEnabled)
      ?? Self.default.inAppNotificationsEnabled
    notificationSoundEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .notificationSoundEnabled)
      ?? Self.default.notificationSoundEnabled
    systemNotificationsEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .systemNotificationsEnabled)
      ?? Self.default.systemNotificationsEnabled
    moveNotifiedWorktreeToTop =
      try container.decodeIfPresent(Bool.self, forKey: .moveNotifiedWorktreeToTop)
      ?? Self.default.moveNotifiedWorktreeToTop
    analyticsEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .analyticsEnabled)
      ?? Self.default.analyticsEnabled
    crashReportsEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .crashReportsEnabled)
      ?? Self.default.crashReportsEnabled
    githubIntegrationEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .githubIntegrationEnabled)
      ?? Self.default.githubIntegrationEnabled
    deleteBranchOnDeleteWorktree =
      try container.decodeIfPresent(Bool.self, forKey: .deleteBranchOnDeleteWorktree)
      ?? Self.default.deleteBranchOnDeleteWorktree
    // `try?` intentionally swallows decoding errors (e.g. unrecognized raw values
    // from a future app version) and falls through to the legacy migration path,
    // which defaults to `nil`. Silently resetting the preference is acceptable
    // because `nil` (do nothing) is the safest default.
    if let action = try? container.decodeIfPresent(MergedWorktreeAction.self, forKey: .mergedWorktreeAction) {
      mergedWorktreeAction = action
    } else {
      if let legacyBool = try legacy.decodeIfPresent(
        Bool.self,
        forKey: LegacyCodingKey(stringValue: "automaticallyArchiveMergedWorktrees")!
      ) {
        mergedWorktreeAction = legacyBool ? .archive : Self.default.mergedWorktreeAction
      } else {
        mergedWorktreeAction = Self.default.mergedWorktreeAction
      }
    }
    promptForWorktreeCreation =
      try container.decodeIfPresent(Bool.self, forKey: .promptForWorktreeCreation)
      ?? Self.default.promptForWorktreeCreation
    fetchOriginBeforeWorktreeCreation =
      try container.decodeIfPresent(Bool.self, forKey: .fetchOriginBeforeWorktreeCreation)
      ?? Self.default.fetchOriginBeforeWorktreeCreation
    copyIgnoredOnWorktreeCreate =
      try container.decodeIfPresent(Bool.self, forKey: .copyIgnoredOnWorktreeCreate)
      ?? Self.default.copyIgnoredOnWorktreeCreate
    copyUntrackedOnWorktreeCreate =
      try container.decodeIfPresent(Bool.self, forKey: .copyUntrackedOnWorktreeCreate)
      ?? Self.default.copyUntrackedOnWorktreeCreate
    pullRequestMergeStrategy =
      try container.decodeIfPresent(PullRequestMergeStrategy.self, forKey: .pullRequestMergeStrategy)
      ?? Self.default.pullRequestMergeStrategy
    // Existing files predate this key; only fresh installs get `true` via `Self.default`.
    terminalThemeSyncEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .terminalThemeSyncEnabled)
      ?? false
    hideSingleTabBar =
      try container.decodeIfPresent(Bool.self, forKey: .hideSingleTabBar)
      ?? Self.default.hideSingleTabBar
    // Migrate from the old Bool `allowArbitraryDeeplinkInput` to the new enum.
    if let policy = try container.decodeIfPresent(AutomatedActionPolicy.self, forKey: .automatedActionPolicy) {
      automatedActionPolicy = policy
    } else if let legacyBool = try legacy.decodeIfPresent(
      Bool.self, forKey: LegacyCodingKey(stringValue: "allowArbitraryDeeplinkInput")!)
    {
      automatedActionPolicy = legacyBool ? .always : .never
    } else {
      automatedActionPolicy = Self.default.automatedActionPolicy
    }
    defaultWorktreeBaseDirectoryPath =
      try container.decodeIfPresent(String.self, forKey: .defaultWorktreeBaseDirectoryPath)
      ?? Self.default.defaultWorktreeBaseDirectoryPath
    // Reject unrecognized values from corrupted or hand-edited settings files.
    autoDeleteArchivedWorktreesAfterDays =
      (try container.decodeIfPresent(Int.self, forKey: .autoDeleteArchivedWorktreesAfterDays))
      .flatMap(AutoDeletePeriod.init(rawValue:))
      ?? Self.default.autoDeleteArchivedWorktreesAfterDays
    shortcutOverrides =
      try container.decodeIfPresent([AppShortcutID: AppShortcutOverride].self, forKey: .shortcutOverrides)
      ?? Self.default.shortcutOverrides
    // Force `.custom` so a forged `kind` can't hijack the primary toolbar slot.
    // No legacy migration here, so missing-key and corrupt-array both collapse
    // to `[]` (unlike `RepositorySettings.scripts` which distinguishes them).
    let decoded: [ScriptDefinition] = container.decodeLossyArrayIfPresent(forKey: .globalScripts) ?? []
    globalScripts = decoded.map {
      var script = $0
      // Intentionally one-way — every load rewrites kind to `.custom`. Don't
      // remove this assignment if a future schema legitimately needs another
      // kind for globals; introduce a separate field instead.
      script.kind = .custom
      if script.name.isEmpty { script.name = ScriptKind.custom.defaultName }
      return script
    }
    // Lossy: a malformed entry is dropped, a missing key collapses to `[]`.
    remoteRepositories = container.decodeLossyArrayIfPresent(forKey: .remoteRepositories) ?? []
    richAgentNotificationsEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .richAgentNotificationsEnabled)
      ?? Self.default.richAgentNotificationsEnabled
    agentPresenceBadgesEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .agentPresenceBadgesEnabled)
      ?? Self.default.agentPresenceBadgesEnabled
    autoUpdateAgentIntegrationsEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .autoUpdateAgentIntegrationsEnabled)
      ?? Self.default.autoUpdateAgentIntegrationsEnabled
    // Reject unrecognized values from corrupted or hand-edited settings files.
    // Legacy `confirmBeforeQuit: false` users explicitly opted out of the
    // dialog; `.auto` would silently re-enable it. Map `false` to `.never`
    // and `true` to `.always` so the strictness intent survives upgrade.
    if let raw = try container.decodeIfPresent(String.self, forKey: .confirmQuitMode),
      let mode = ConfirmQuitMode(rawValue: raw)
    {
      confirmQuitMode = mode
    } else if let legacyConfirmBeforeQuit = try legacy.decodeIfPresent(
      Bool.self, forKey: LegacyCodingKey(stringValue: "confirmBeforeQuit")!)
    {
      confirmQuitMode = legacyConfirmBeforeQuit ? .always : .never
    } else {
      confirmQuitMode = Self.default.confirmQuitMode
    }
    terminateSessionsOnQuit =
      try container.decodeIfPresent(Bool.self, forKey: .terminateSessionsOnQuit)
      ?? Self.default.terminateSessionsOnQuit
  }
}
