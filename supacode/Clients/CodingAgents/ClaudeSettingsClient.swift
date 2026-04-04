import ComposableArchitecture
import Foundation

struct ClaudeSettingsClient: Sendable {
  var checkInstalled: @Sendable (Bool) async -> Bool
  var installProgress: @Sendable () async throws -> Void
  var installNotifications: @Sendable () async throws -> Void
  var uninstallProgress: @Sendable () async throws -> Void
  var uninstallNotifications: @Sendable () async throws -> Void
}

extension ClaudeSettingsClient: DependencyKey {
  static let liveValue = Self(
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
  static let testValue = Self(
    checkInstalled: { _ in false },
    installProgress: {},
    installNotifications: {},
    uninstallProgress: {},
    uninstallNotifications: {}
  )
}

extension DependencyValues {
  var claudeSettingsClient: ClaudeSettingsClient {
    get { self[ClaudeSettingsClient.self] }
    set { self[ClaudeSettingsClient.self] = newValue }
  }
}
