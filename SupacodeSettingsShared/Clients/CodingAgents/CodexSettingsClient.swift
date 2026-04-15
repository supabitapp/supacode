import ComposableArchitecture
import Foundation

public nonisolated struct CodexSettingsClient: Sendable {
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

extension CodexSettingsClient: DependencyKey {
  public static let liveValue = Self(
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
  public static let testValue = Self(
    checkInstalled: { _ in false },
    installProgress: {},
    installNotifications: {},
    uninstallProgress: {},
    uninstallNotifications: {}
  )
}

public extension DependencyValues {
  var codexSettingsClient: CodexSettingsClient {
    get { self[CodexSettingsClient.self] }
    set { self[CodexSettingsClient.self] = newValue }
  }
}
