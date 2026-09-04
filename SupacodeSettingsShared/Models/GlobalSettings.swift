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

/// Per-worktree ceiling on retained notifications. Bounds memory and the
/// inspector's render cost so a long-lived worktree can't accumulate an
/// unbounded backlog. Finite tiers store the count as their raw value;
/// `.unlimited` is a sentinel (see below).
public nonisolated enum NotificationRetentionLimit: Int, Codable, CaseIterable, Sendable {
  case oneHundred = 100
  case twoHundred = 200
  case fiveHundred = 500
  case oneThousand = 1000
  /// No cap. The raw value is only the on-disk token (an enum case can't be
  /// `= .max`, which isn't a literal); `limit` maps it to `Int.max`.
  case unlimited = 0

  /// Maximum notifications kept per worktree; `.unlimited` maps to `Int.max`,
  /// so trimming's `count > limit` guard is a no-op with no special-casing.
  public var limit: Int { self == .unlimited ? .max : rawValue }

  /// The value new installs get; the picker tags it with "Default".
  public static let defaultValue: NotificationRetentionLimit = .twoHundred

  public var label: String {
    switch self {
    case .oneHundred: "100"
    case .twoHundred: "200"
    case .fiveHundred: "500"
    case .oneThousand: "1,000"
    case .unlimited: "Unlimited"
    }
  }
}

/// Which worktrees the notification inspector lists. Persisted across sessions.
public nonisolated enum NotificationScope: String, Codable, CaseIterable, Sendable {
  case all
  case currentWorktree

  public static let defaultValue: NotificationScope = .all
}

/// How Supacode combines the user's own Ghostty config with the optional
/// Supacode-specific config at `~/.supacode/ghostty.config`.
public nonisolated enum GhosttyUserConfigMode: String, Codable, CaseIterable, Sendable {
  /// Load the standard Ghostty config first, then layer the Supacode config on
  /// top so it overrides conflicts and merges the rest. The default.
  case mergeAfterDefault
  /// Ignore the standard Ghostty config and read only the Supacode config. Falls
  /// back to the standard config when the Supacode file is missing or empty.
  case exclusive

  public var label: String {
    switch self {
    case .mergeAfterDefault: "Merge after Ghostty config"
    case .exclusive: "Use only the Supacode config"
    }
  }

  public var subtitle: String {
    switch self {
    case .mergeAfterDefault: "Read your Ghostty config first, then apply the Supacode config on top."
    case .exclusive: "Ignore your Ghostty config. Only the Supacode config is read."
    }
  }
}

/// Whether moving the pointer over a split pane focuses it (focus follows
/// mouse), and for which content kinds. An enum rather than a Bool so future
/// content kinds can opt in independently.
public nonisolated enum HoverFocusMode: String, Codable, CaseIterable, Sendable {
  /// Focus never follows the pointer. The default.
  case never
  /// Hovering a terminal split pane focuses it, within the key window.
  case terminals

  public var label: String {
    switch self {
    case .never: "Never"
    case .terminals: "Terminals"
    }
  }
}

public nonisolated struct GlobalSettings: Codable, Equatable, Sendable {
  public var appearanceMode: AppearanceMode
  public var defaultEditorID: String
  public var updateChannel: UpdateChannel
  public var updatesAutomaticallyCheckForUpdates: Bool
  public var updatesAutomaticallyDownloadUpdates: Bool
  public var inAppNotificationsEnabled: Bool
  public var notificationSound: NotificationSound
  public var systemNotificationsEnabled: Bool
  public var muteNotificationsForActiveSurface: Bool
  public var moveNotifiedWorktreeToTop: Bool
  public var notificationRetentionLimit: NotificationRetentionLimit
  public var notificationScope: NotificationScope
  /// Whether the notification inspector groups its list into worktree sections.
  public var notificationsGroupedByWorktree: Bool
  /// Whether the notification inspector hides read notifications.
  public var notificationsUnreadOnly: Bool
  public var analyticsEnabled: Bool
  public var crashReportsEnabled: Bool
  public var githubIntegrationEnabled: Bool
  /// Per-forge integration enablement keyed by forge id. GitHub stays on the
  /// legacy flag above so downgraded builds keep their setting.
  public var forgeEnabledByID: [String: Bool]
  public var deleteBranchOnDeleteWorktree: Bool
  public var mergedWorktreeAction: MergedWorktreeAction
  public var promptForWorktreeCreation: Bool
  public var fetchOriginBeforeWorktreeCreation: Bool
  public var defaultWorktreeBaseDirectoryPath: String?
  public var copyIgnoredOnWorktreeCreate: Bool
  public var copyUntrackedOnWorktreeCreate: Bool
  public var pullRequestMergeStrategy: PullRequestMergeStrategy
  public var terminalThemeSyncEnabled: Bool
  /// Whether the optional `~/.supacode/ghostty.config` merges after the standard
  /// Ghostty config or replaces it. Inert until that file exists.
  public var ghosttyUserConfigMode: GhosttyUserConfigMode
  public var automatedActionPolicy: AutomatedActionPolicy
  public var autoDeleteArchivedWorktreesAfterDays: AutoDeletePeriod?
  public var shortcutOverrides: [AppShortcutID: AppShortcutOverride]
  /// Scripts shared across every repository. Always `.custom` kind.
  public var globalScripts: [ScriptDefinition]
  /// Global fallback for opening a File Explorer file when the repo sets none, with its path in
  /// `SUPACODE_FILE_PATH`. Empty uses the system default app. A hook, never in the script menu.
  public var openFileScript: String
  public var richAgentNotificationsEnabled: Bool
  public var agentPresenceBadgesEnabled: Bool
  public var confirmQuitMode: ConfirmQuitMode
  /// When true, user-initiated closes ask for confirmation when a terminal
  /// surface has foreground work that Ghostty considers unsafe to interrupt.
  /// Superseded by `confirmCloseTab`; read only by the legacy terminal path.
  public var confirmCloseSurface: Bool
  /// How aggressively to confirm before closing a tab: only when the tab is
  /// busy (default), always, or never.
  public var confirmCloseTab: ConfirmCloseTabMode
  /// When true, quitting Supacode also closes every terminal tab and tears
  /// down zmx sessions, local and host-side, so nothing keeps running in the
  /// background. Default off because persistence is the headline feature.
  public var terminateSessionsOnQuit: Bool
  /// When true, remote surfaces wrap their session in zmx on the host when
  /// the host has it installed, so the session survives disconnects.
  public var remoteSessionPersistenceEnabled: Bool
  /// Where Supacode appears: Dock, menu bar, or both.
  public var appVisibility: AppVisibility
  /// Beta: hidden terminal tabs release their renderer after a few minutes of
  /// inactivity and reconnect when viewed. On by default.
  public var terminalHibernationEnabled: Bool
  /// Accessibility size for the app chrome's text. Drives the scale published at
  /// each window root. Defaults to the unmodified system size.
  public var chromeTextSize: ChromeTextSize
  /// Gates all background repository polling (remote SSH, PR checks, reconcile).
  /// On by default; disable to stop SSH passphrase prompts or GitHub rate limiting.
  public var automaticRepositoryRefreshEnabled: Bool
  public var automaticRepositoryRefreshInterval: Int
  /// Whether hovering a split pane focuses it (focus follows mouse). Off by default.
  public var hoverFocusMode: HoverFocusMode
  /// System-wide chord that toggles the app; nil (the default) leaves it unbound.
  public var globalToggleVisibilityHotkey: AppShortcutOverride?

  public static let `default` = GlobalSettings(
    appearanceMode: .dark,
    defaultEditorID: OpenWorktreeAction.automaticSettingsID,
    updateChannel: .stable,
    updatesAutomaticallyCheckForUpdates: true,
    updatesAutomaticallyDownloadUpdates: false,
    inAppNotificationsEnabled: true,
    notificationSound: .hero,
    systemNotificationsEnabled: false,
    muteNotificationsForActiveSurface: true,
    moveNotifiedWorktreeToTop: false,
    notificationRetentionLimit: .defaultValue,
    notificationScope: .defaultValue,
    notificationsGroupedByWorktree: false,
    notificationsUnreadOnly: false,
    analyticsEnabled: true,
    crashReportsEnabled: true,
    githubIntegrationEnabled: true,
    forgeEnabledByID: [:],
    deleteBranchOnDeleteWorktree: true,
    mergedWorktreeAction: .ignore,
    promptForWorktreeCreation: true,
    fetchOriginBeforeWorktreeCreation: true,
    copyIgnoredOnWorktreeCreate: false,
    copyUntrackedOnWorktreeCreate: false,
    pullRequestMergeStrategy: .merge,
    terminalThemeSyncEnabled: true,
    ghosttyUserConfigMode: .mergeAfterDefault,
    automatedActionPolicy: .cliOnly,
    defaultWorktreeBaseDirectoryPath: nil,
    autoDeleteArchivedWorktreesAfterDays: nil,
    shortcutOverrides: [:],
    globalScripts: [],
    openFileScript: "",
    richAgentNotificationsEnabled: true,
    agentPresenceBadgesEnabled: true,
    confirmQuitMode: .auto,
    confirmCloseSurface: true,
    confirmCloseTab: .busy,
    terminateSessionsOnQuit: false,
    remoteSessionPersistenceEnabled: true,
    appVisibility: .dockAndMenuBar,
    chromeTextSize: .default
  )

  public init(
    appearanceMode: AppearanceMode,
    defaultEditorID: String,
    updateChannel: UpdateChannel,
    updatesAutomaticallyCheckForUpdates: Bool,
    updatesAutomaticallyDownloadUpdates: Bool,
    inAppNotificationsEnabled: Bool,
    notificationSound: NotificationSound = .hero,
    systemNotificationsEnabled: Bool = false,
    muteNotificationsForActiveSurface: Bool = true,
    moveNotifiedWorktreeToTop: Bool,
    notificationRetentionLimit: NotificationRetentionLimit = .defaultValue,
    notificationScope: NotificationScope = .defaultValue,
    notificationsGroupedByWorktree: Bool = false,
    notificationsUnreadOnly: Bool = false,
    analyticsEnabled: Bool,
    crashReportsEnabled: Bool,
    githubIntegrationEnabled: Bool,
    forgeEnabledByID: [String: Bool] = [:],
    deleteBranchOnDeleteWorktree: Bool,
    mergedWorktreeAction: MergedWorktreeAction = .ignore,
    promptForWorktreeCreation: Bool,
    fetchOriginBeforeWorktreeCreation: Bool = true,
    copyIgnoredOnWorktreeCreate: Bool = false,
    copyUntrackedOnWorktreeCreate: Bool = false,
    pullRequestMergeStrategy: PullRequestMergeStrategy = .merge,
    terminalThemeSyncEnabled: Bool = true,
    ghosttyUserConfigMode: GhosttyUserConfigMode = .mergeAfterDefault,
    automatedActionPolicy: AutomatedActionPolicy = .cliOnly,
    defaultWorktreeBaseDirectoryPath: String? = nil,
    autoDeleteArchivedWorktreesAfterDays: AutoDeletePeriod? = nil,
    shortcutOverrides: [AppShortcutID: AppShortcutOverride] = [:],
    globalScripts: [ScriptDefinition] = [],
    openFileScript: String = "",
    richAgentNotificationsEnabled: Bool = true,
    agentPresenceBadgesEnabled: Bool = true,
    confirmQuitMode: ConfirmQuitMode = .auto,
    confirmCloseSurface: Bool = true,
    confirmCloseTab: ConfirmCloseTabMode = .busy,
    terminateSessionsOnQuit: Bool = false,
    remoteSessionPersistenceEnabled: Bool = true,
    appVisibility: AppVisibility = .dockAndMenuBar,
    terminalHibernationEnabled: Bool = true,
    chromeTextSize: ChromeTextSize = .default,
    automaticRepositoryRefreshEnabled: Bool = true,
    automaticRepositoryRefreshInterval: Int = 300,
    hoverFocusMode: HoverFocusMode = .never,
    globalToggleVisibilityHotkey: AppShortcutOverride? = nil
  ) {
    self.appearanceMode = appearanceMode
    self.defaultEditorID = defaultEditorID
    self.updateChannel = updateChannel
    self.updatesAutomaticallyCheckForUpdates = updatesAutomaticallyCheckForUpdates
    self.updatesAutomaticallyDownloadUpdates = updatesAutomaticallyDownloadUpdates
    self.inAppNotificationsEnabled = inAppNotificationsEnabled
    self.notificationSound = notificationSound
    self.systemNotificationsEnabled = systemNotificationsEnabled
    self.muteNotificationsForActiveSurface = muteNotificationsForActiveSurface
    self.moveNotifiedWorktreeToTop = moveNotifiedWorktreeToTop
    self.notificationRetentionLimit = notificationRetentionLimit
    self.notificationScope = notificationScope
    self.notificationsGroupedByWorktree = notificationsGroupedByWorktree
    self.notificationsUnreadOnly = notificationsUnreadOnly
    self.analyticsEnabled = analyticsEnabled
    self.crashReportsEnabled = crashReportsEnabled
    self.githubIntegrationEnabled = githubIntegrationEnabled
    self.forgeEnabledByID = forgeEnabledByID
    self.deleteBranchOnDeleteWorktree = deleteBranchOnDeleteWorktree
    self.mergedWorktreeAction = mergedWorktreeAction
    self.promptForWorktreeCreation = promptForWorktreeCreation
    self.fetchOriginBeforeWorktreeCreation = fetchOriginBeforeWorktreeCreation
    self.copyIgnoredOnWorktreeCreate = copyIgnoredOnWorktreeCreate
    self.copyUntrackedOnWorktreeCreate = copyUntrackedOnWorktreeCreate
    self.pullRequestMergeStrategy = pullRequestMergeStrategy
    self.terminalThemeSyncEnabled = terminalThemeSyncEnabled
    self.ghosttyUserConfigMode = ghosttyUserConfigMode
    self.automatedActionPolicy = automatedActionPolicy
    self.defaultWorktreeBaseDirectoryPath = defaultWorktreeBaseDirectoryPath
    self.autoDeleteArchivedWorktreesAfterDays = autoDeleteArchivedWorktreesAfterDays
    self.shortcutOverrides = shortcutOverrides
    self.globalScripts = globalScripts
    self.openFileScript = openFileScript
    self.richAgentNotificationsEnabled = richAgentNotificationsEnabled
    self.agentPresenceBadgesEnabled = agentPresenceBadgesEnabled
    self.confirmQuitMode = confirmQuitMode
    self.confirmCloseSurface = confirmCloseSurface
    self.confirmCloseTab = confirmCloseTab
    self.terminateSessionsOnQuit = terminateSessionsOnQuit
    self.remoteSessionPersistenceEnabled = remoteSessionPersistenceEnabled
    self.appVisibility = appVisibility
    self.terminalHibernationEnabled = terminalHibernationEnabled
    self.chromeTextSize = chromeTextSize
    self.automaticRepositoryRefreshEnabled = automaticRepositoryRefreshEnabled
    self.automaticRepositoryRefreshInterval = automaticRepositoryRefreshInterval
    self.hoverFocusMode = hoverFocusMode
    self.globalToggleVisibilityHotkey = globalToggleVisibilityHotkey
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
    // Fold the removed `notificationSoundEnabled` toggle: off becomes `.never`,
    // on the default sound. `try?` keeps an unrecognized raw value from failing
    // the whole decode.
    if let sound = try? container.decodeIfPresent(NotificationSound.self, forKey: .notificationSound) {
      notificationSound = sound
    } else if let soundEnabled = try legacy.decodeIfPresent(
      Bool.self, forKey: LegacyCodingKey(stringValue: "notificationSoundEnabled")!)
    {
      notificationSound = soundEnabled ? Self.default.notificationSound : .never
    } else {
      notificationSound = Self.default.notificationSound
    }
    systemNotificationsEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .systemNotificationsEnabled)
      ?? Self.default.systemNotificationsEnabled
    muteNotificationsForActiveSurface =
      try container.decodeIfPresent(Bool.self, forKey: .muteNotificationsForActiveSurface)
      ?? Self.default.muteNotificationsForActiveSurface
    moveNotifiedWorktreeToTop =
      try container.decodeIfPresent(Bool.self, forKey: .moveNotifiedWorktreeToTop)
      ?? Self.default.moveNotifiedWorktreeToTop
    // Reject unrecognized values from corrupted or hand-edited settings files.
    notificationRetentionLimit =
      (try container.decodeIfPresent(Int.self, forKey: .notificationRetentionLimit))
      .flatMap(NotificationRetentionLimit.init(rawValue:))
      ?? Self.default.notificationRetentionLimit
    // Fall back instead of throwing, which would reset the whole file.
    notificationScope =
      ((try? container.decodeIfPresent(String.self, forKey: .notificationScope)) ?? nil)
      .flatMap(NotificationScope.init(rawValue:))
      ?? Self.default.notificationScope
    notificationsGroupedByWorktree =
      try container.decodeIfPresent(Bool.self, forKey: .notificationsGroupedByWorktree)
      ?? Self.default.notificationsGroupedByWorktree
    notificationsUnreadOnly =
      try container.decodeIfPresent(Bool.self, forKey: .notificationsUnreadOnly)
      ?? Self.default.notificationsUnreadOnly
    analyticsEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .analyticsEnabled)
      ?? Self.default.analyticsEnabled
    crashReportsEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .crashReportsEnabled)
      ?? Self.default.crashReportsEnabled
    githubIntegrationEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .githubIntegrationEnabled)
      ?? Self.default.githubIntegrationEnabled
    let decodedForgeEnabledByID =
      (try? container.decodeIfPresent([String: Bool].self, forKey: .forgeEnabledByID))
      .flatMap { $0 }
    if let decodedForgeEnabledByID {
      forgeEnabledByID = decodedForgeEnabledByID
    } else if !githubIntegrationEnabled {
      // A pre-forge file with the legacy integration off opted out of forge
      // polling entirely; new forges must not resurrect it on upgrade.
      forgeEnabledByID = ["gitlab": false]
    } else {
      forgeEnabledByID = Self.default.forgeEnabledByID
    }
    deleteBranchOnDeleteWorktree =
      try container.decodeIfPresent(Bool.self, forKey: .deleteBranchOnDeleteWorktree)
      ?? Self.default.deleteBranchOnDeleteWorktree
    // An unrecognized raw value (`try?`) or an absent key both resolve to `.ignore`
    // (do nothing) via the legacy path, the safe default.
    if let action = try? container.decodeIfPresent(MergedWorktreeAction.self, forKey: .mergedWorktreeAction) {
      mergedWorktreeAction = action
    } else if let legacyBool = try legacy.decodeIfPresent(
      Bool.self,
      forKey: LegacyCodingKey(stringValue: "automaticallyArchiveMergedWorktrees")!
    ) {
      mergedWorktreeAction = legacyBool ? .archive : Self.default.mergedWorktreeAction
    } else {
      mergedWorktreeAction = Self.default.mergedWorktreeAction
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
    // Reject unrecognized values (and a mistyped key) rather than throwing, which
    // would reset the whole file to defaults. Pre-feature files omit this key.
    ghosttyUserConfigMode =
      (try? container.decode(GhosttyUserConfigMode.self, forKey: .ghosttyUserConfigMode))
      ?? Self.default.ghosttyUserConfigMode
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
    openFileScript =
      try container.decodeIfPresent(String.self, forKey: .openFileScript)
      ?? Self.default.openFileScript
    richAgentNotificationsEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .richAgentNotificationsEnabled)
      ?? Self.default.richAgentNotificationsEnabled
    agentPresenceBadgesEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .agentPresenceBadgesEnabled)
      ?? Self.default.agentPresenceBadgesEnabled
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
    confirmCloseSurface =
      try container.decodeIfPresent(Bool.self, forKey: .confirmCloseSurface)
      ?? Self.default.confirmCloseSurface
    // Prefer the explicit mode; otherwise carry the legacy bool's intent
    // (confirm-when-busy vs never), and default to `.busy`.
    if let raw = try container.decodeIfPresent(String.self, forKey: .confirmCloseTab),
      let mode = ConfirmCloseTabMode(rawValue: raw)
    {
      confirmCloseTab = mode
    } else {
      confirmCloseTab = confirmCloseSurface ? .busy : .never
    }
    terminateSessionsOnQuit =
      try container.decodeIfPresent(Bool.self, forKey: .terminateSessionsOnQuit)
      ?? Self.default.terminateSessionsOnQuit
    remoteSessionPersistenceEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .remoteSessionPersistenceEnabled)
      ?? Self.default.remoteSessionPersistenceEnabled
    // Reject unrecognized values (and a mistyped key) from corrupted or
    // hand-edited settings files: a throw here resets the whole file to defaults.
    appVisibility =
      ((try? container.decodeIfPresent(String.self, forKey: .appVisibility)) ?? nil)
      .flatMap(AppVisibility.init(rawValue:))
      ?? Self.default.appVisibility
    // Pre-feature files omit this key; the Beta feature falls back to the default.
    terminalHibernationEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .terminalHibernationEnabled)
      ?? Self.default.terminalHibernationEnabled
    // Old settings files predate this key; they migrate to the system size. An
    // unrecognized value falls back the same way rather than throwing, which
    // would reset the whole file to defaults.
    chromeTextSize =
      ((try? container.decodeIfPresent(String.self, forKey: .chromeTextSize)) ?? nil)
      .flatMap(ChromeTextSize.init(rawValue:))
      ?? Self.default.chromeTextSize
    // Pre-feature files omit this key; background refresh defaults on.
    automaticRepositoryRefreshEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .automaticRepositoryRefreshEnabled)
      ?? Self.default.automaticRepositoryRefreshEnabled
    automaticRepositoryRefreshInterval =
      try container.decodeIfPresent(Int.self, forKey: .automaticRepositoryRefreshInterval)
      ?? Self.default.automaticRepositoryRefreshInterval
    // Decode the raw string so an unrecognized future mode falls back rather
    // than throwing (which would reset the whole file to defaults).
    hoverFocusMode =
      ((try? container.decodeIfPresent(String.self, forKey: .hoverFocusMode)) ?? nil)
      .flatMap(HoverFocusMode.init(rawValue:))
      ?? Self.default.hoverFocusMode
    // A malformed value falls back to unbound instead of throwing, which would
    // reset the whole file to defaults.
    globalToggleVisibilityHotkey =
      ((try? container.decodeIfPresent(AppShortcutOverride.self, forKey: .globalToggleVisibilityHotkey)) ?? nil)
      ?? Self.default.globalToggleVisibilityHotkey
  }
}

extension GlobalSettings {
  /// Effective enablement for one forge integration. GitHub reads the legacy
  /// stored flag so downgraded builds keep their setting.
  public func forgeIntegrationEnabled(forID id: String) -> Bool {
    guard id != "github" else { return githubIntegrationEnabled }
    return forgeEnabledByID[id] ?? true
  }

  public mutating func setForgeIntegrationEnabled(_ enabled: Bool, forID id: String) {
    guard id != "github" else {
      githubIntegrationEnabled = enabled
      return
    }
    forgeEnabledByID[id] = enabled
  }
}
