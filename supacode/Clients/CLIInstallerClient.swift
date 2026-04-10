import ComposableArchitecture
import Foundation

struct CLIInstallerClient: Sendable {
  var checkInstalled: @Sendable () async -> Bool
  var install: @Sendable () async throws -> Void
  var uninstall: @Sendable () async throws -> Void
}

extension CLIInstallerClient: DependencyKey {
  static let liveValue = Self(
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
  static let testValue = Self(
    checkInstalled: unimplemented("CLIInstallerClient.checkInstalled", placeholder: false),
    install: unimplemented("CLIInstallerClient.install"),
    uninstall: unimplemented("CLIInstallerClient.uninstall")
  )
}

extension DependencyValues {
  var cliInstallerClient: CLIInstallerClient {
    get { self[CLIInstallerClient.self] }
    set { self[CLIInstallerClient.self] = newValue }
  }
}
