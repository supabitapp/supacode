import ComposableArchitecture
import Foundation

public nonisolated struct ClaudeSettingsClient: Sendable {
  public var checkInstalled: @Sendable (Bool) async -> Bool
  public var installProgress: @Sendable () async throws -> Void
  public var installNotifications: @Sendable () async throws -> Void
  public var uninstallProgress: @Sendable () async throws -> Void
  public var uninstallNotifications: @Sendable () async throws -> Void

  public init(
    checkInstalled: @escaping @Sendable (Bool) async -> Bool,
    installProgress: @escaping @Sendable () async throws -> Void,
    installNotifications: @escaping @Sendable () async throws -> Void,
    uninstallProgress: @escaping @Sendable () async throws -> Void,
    uninstallNotifications: @escaping @Sendable () async throws -> Void
  ) {
    self.checkInstalled = checkInstalled
    self.installProgress = installProgress
    self.installNotifications = installNotifications
    self.uninstallProgress = uninstallProgress
    self.uninstallNotifications = uninstallNotifications
  }
}

extension ClaudeSettingsClient: DependencyKey {
  public static let liveValue = Self(
    checkInstalled: { progress in
      ClaudeSettingsInstaller().isInstalled(progress: progress)
    },
    installProgress: {
      try ClaudeSettingsInstaller().installProgressHooks()
    },
    installNotifications: {
      try ClaudeSettingsInstaller().installNotificationHooks()
    },
    uninstallProgress: {
      try ClaudeSettingsInstaller().uninstallProgressHooks()
    },
    uninstallNotifications: {
      try ClaudeSettingsInstaller().uninstallNotificationHooks()
    }
  )
  public static let testValue = Self(
    checkInstalled: { _ in false },
    installProgress: {},
    installNotifications: {},
    uninstallProgress: {},
    uninstallNotifications: {}
  )
}

extension DependencyValues {
  public var claudeSettingsClient: ClaudeSettingsClient {
    get { self[ClaudeSettingsClient.self] }
    set { self[ClaudeSettingsClient.self] = newValue }
  }
}
