import ComposableArchitecture
import Foundation

public nonisolated struct CLIInstallerClient: Sendable {
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

extension CLIInstallerClient: DependencyKey {
  public static let liveValue = Self(
    checkInstalled: {
      CLIInstaller().isInstalled()
    },
    install: {
      try await MainActor.run { try CLIInstaller().install() }
    },
    uninstall: {
      try await MainActor.run { try CLIInstaller().uninstall() }
    }
  )
  public static let testValue = Self(
    checkInstalled: { false },
    install: {},
    uninstall: {}
  )
}

extension DependencyValues {
  public var cliInstallerClient: CLIInstallerClient {
    get { self[CLIInstallerClient.self] }
    set { self[CLIInstallerClient.self] = newValue }
  }
}
