import ComposableArchitecture
import Foundation

public nonisolated struct KiroSettingsClient: Sendable {
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

extension KiroSettingsClient: DependencyKey {
  public static let liveValue = Self(
    checkInstalled: { progress in
      KiroSettingsInstaller().isInstalled(progress: progress)
    },
    installProgress: {
      try await KiroSettingsInstaller().installProgressHooks()
    },
    installNotifications: {
      try await KiroSettingsInstaller().installNotificationHooks()
    },
    uninstallProgress: {
      try KiroSettingsInstaller().uninstallProgressHooks()
    },
    uninstallNotifications: {
      try KiroSettingsInstaller().uninstallNotificationHooks()
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
  public var kiroSettingsClient: KiroSettingsClient {
    get { self[KiroSettingsClient.self] }
    set { self[KiroSettingsClient.self] = newValue }
  }
}
