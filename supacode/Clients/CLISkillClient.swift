import ComposableArchitecture
import Foundation

struct CLISkillClient: Sendable {
  var checkInstalled: @Sendable (SkillAgent) async -> Bool
  var install: @Sendable (SkillAgent) async throws -> Void
  var uninstall: @Sendable (SkillAgent) async throws -> Void
}

extension CLISkillClient: DependencyKey {
  static let liveValue = Self(
    checkInstalled: { CLISkillInstaller().isInstalled($0) },
    install: { try CLISkillInstaller().install($0) },
    uninstall: { try CLISkillInstaller().uninstall($0) },
  )
  static let testValue = Self(
    checkInstalled: unimplemented("CLISkillClient.checkInstalled", placeholder: false),
    install: unimplemented("CLISkillClient.install"),
    uninstall: unimplemented("CLISkillClient.uninstall"),
  )
}

extension DependencyValues {
  var cliSkillClient: CLISkillClient {
    get { self[CLISkillClient.self] }
    set { self[CLISkillClient.self] = newValue }
  }
}
