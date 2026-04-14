import ComposableArchitecture
import Foundation

struct KiroSettingsClient: Sendable {
  var checkInstalled: @Sendable (Bool) async -> Bool
  var installProgress: @Sendable () async throws -> Void
  var installNotifications: @Sendable () async throws -> Void
  var uninstallProgress: @Sendable () async throws -> Void
  var uninstallNotifications: @Sendable () async throws -> Void
}

extension KiroSettingsClient: DependencyKey {
  static let liveValue = Self(
    checkInstalled: { progress in
      KiroSettingsInstaller().isInstalled(progress: progress)
    },
    installProgress: {
      try KiroSettingsInstaller().installProgressHooks()
    },
    installNotifications: {
      try KiroSettingsInstaller().installNotificationHooks()
    },
    uninstallProgress: {
      try KiroSettingsInstaller().uninstallProgressHooks()
    },
    uninstallNotifications: {
      try KiroSettingsInstaller().uninstallNotificationHooks()
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
  var kiroSettingsClient: KiroSettingsClient {
    get { self[KiroSettingsClient.self] }
    set { self[KiroSettingsClient.self] = newValue }
  }
}
