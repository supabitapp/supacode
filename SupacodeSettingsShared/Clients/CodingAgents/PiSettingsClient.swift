import ComposableArchitecture
import Foundation

public nonisolated struct PiSettingsClient: Sendable {
  public var checkInstalled: @Sendable () async -> Bool
  public var install: @Sendable () async throws -> Void
  public var uninstall: @Sendable () async throws -> Void

  public init(
    checkInstalled: @escaping @Sendable () async -> Bool,
    install: @escaping @Sendable () async throws -> Void,
    uninstall: @escaping @Sendable () async throws -> Void
  ) {
    self.checkInstalled = checkInstalled
    self.install = install
    self.uninstall = uninstall
  }
}

extension PiSettingsClient: DependencyKey {
  public static let liveValue = Self(
    checkInstalled: {
      PiSettingsInstaller().isInstalled()
    },
    install: {
      try PiSettingsInstaller().install()
    },
    uninstall: {
      try PiSettingsInstaller().uninstall()
    }
  )
  public static let testValue = Self(
    checkInstalled: { false },
    install: {},
    uninstall: {}
  )
}

extension DependencyValues {
  public var piSettingsClient: PiSettingsClient {
    get { self[PiSettingsClient.self] }
    set { self[PiSettingsClient.self] = newValue }
  }
}
