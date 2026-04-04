import ComposableArchitecture
import Foundation

struct CodexSettingsClient: Sendable {
  var checkInstalled: @Sendable (Bool) async -> Bool
  var installProgress: @Sendable () async throws -> Void
  var installNotifications: @Sendable () async throws -> Void
  var uninstallProgress: @Sendable () async throws -> Void
  var uninstallNotifications: @Sendable () async throws -> Void
}

extension CodexSettingsClient: DependencyKey {
  static let liveValue = Self(
    checkInstalled: { progress in
      CodexSettingsInstaller().isInstalled(progress: progress)
    },
    installProgress: {
      try await CodexSettingsInstaller().installProgressHooks()
    },
    installNotifications: {
      try await CodexSettingsInstaller().installNotificationHooks()
    },
    uninstallProgress: {
      try CodexSettingsInstaller().uninstallProgressHooks()
    },
    uninstallNotifications: {
      try CodexSettingsInstaller().uninstallNotificationHooks()
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
  var codexSettingsClient: CodexSettingsClient {
    get { self[CodexSettingsClient.self] }
    set { self[CodexSettingsClient.self] = newValue }
  }
}
