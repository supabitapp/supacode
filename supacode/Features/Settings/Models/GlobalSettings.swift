nonisolated struct GlobalSettings: Codable, Equatable, Sendable {
  var appearanceMode: AppearanceMode
  var defaultEditorID: String
  var confirmBeforeQuit: Bool
  var updateChannel: UpdateChannel
  var updatesAutomaticallyCheckForUpdates: Bool
  var updatesAutomaticallyDownloadUpdates: Bool
  var inAppNotificationsEnabled: Bool
  var dockBadgeEnabled: Bool
  var notificationSoundEnabled: Bool
  var analyticsEnabled: Bool
  var crashReportsEnabled: Bool
  var githubIntegrationEnabled: Bool
  var deleteBranchOnDeleteWorktree: Bool
  var automaticallyArchiveMergedWorktrees: Bool

  static let `default` = GlobalSettings(
    appearanceMode: .dark,
    defaultEditorID: OpenWorktreeAction.automaticSettingsID,
    confirmBeforeQuit: true,
    updateChannel: .stable,
    updatesAutomaticallyCheckForUpdates: true,
    updatesAutomaticallyDownloadUpdates: false,
    inAppNotificationsEnabled: true,
    dockBadgeEnabled: true,
    notificationSoundEnabled: true,
    analyticsEnabled: true,
    crashReportsEnabled: true,
    githubIntegrationEnabled: true,
    deleteBranchOnDeleteWorktree: true,
    automaticallyArchiveMergedWorktrees: false
  )

  init(
    appearanceMode: AppearanceMode,
    defaultEditorID: String,
    confirmBeforeQuit: Bool,
    updateChannel: UpdateChannel,
    updatesAutomaticallyCheckForUpdates: Bool,
    updatesAutomaticallyDownloadUpdates: Bool,
    inAppNotificationsEnabled: Bool,
    dockBadgeEnabled: Bool,
    notificationSoundEnabled: Bool,
    analyticsEnabled: Bool,
    crashReportsEnabled: Bool,
    githubIntegrationEnabled: Bool,
    deleteBranchOnDeleteWorktree: Bool,
    automaticallyArchiveMergedWorktrees: Bool
  ) {
    self.appearanceMode = appearanceMode
    self.defaultEditorID = defaultEditorID
    self.confirmBeforeQuit = confirmBeforeQuit
    self.updateChannel = updateChannel
    self.updatesAutomaticallyCheckForUpdates = updatesAutomaticallyCheckForUpdates
    self.updatesAutomaticallyDownloadUpdates = updatesAutomaticallyDownloadUpdates
    self.inAppNotificationsEnabled = inAppNotificationsEnabled
    self.dockBadgeEnabled = dockBadgeEnabled
    self.notificationSoundEnabled = notificationSoundEnabled
    self.analyticsEnabled = analyticsEnabled
    self.crashReportsEnabled = crashReportsEnabled
    self.githubIntegrationEnabled = githubIntegrationEnabled
    self.deleteBranchOnDeleteWorktree = deleteBranchOnDeleteWorktree
    self.automaticallyArchiveMergedWorktrees = automaticallyArchiveMergedWorktrees
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    appearanceMode = try container.decode(AppearanceMode.self, forKey: .appearanceMode)
    defaultEditorID =
      try container.decodeIfPresent(String.self, forKey: .defaultEditorID)
      ?? Self.default.defaultEditorID
    confirmBeforeQuit =
      try container.decodeIfPresent(Bool.self, forKey: .confirmBeforeQuit)
      ?? Self.default.confirmBeforeQuit
    updateChannel =
      try container.decodeIfPresent(UpdateChannel.self, forKey: .updateChannel)
      ?? Self.default.updateChannel
    updatesAutomaticallyCheckForUpdates = try container.decode(Bool.self, forKey: .updatesAutomaticallyCheckForUpdates)
    updatesAutomaticallyDownloadUpdates = try container.decode(Bool.self, forKey: .updatesAutomaticallyDownloadUpdates)
    inAppNotificationsEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .inAppNotificationsEnabled)
      ?? Self.default.inAppNotificationsEnabled
    dockBadgeEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .dockBadgeEnabled)
      ?? Self.default.dockBadgeEnabled
    notificationSoundEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .notificationSoundEnabled)
      ?? Self.default.notificationSoundEnabled
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
    automaticallyArchiveMergedWorktrees =
      try container.decodeIfPresent(Bool.self, forKey: .automaticallyArchiveMergedWorktrees)
      ?? Self.default.automaticallyArchiveMergedWorktrees
  }
}
