import ComposableArchitecture
import Foundation

public nonisolated struct CLISkillClient: Sendable {
  public var checkInstalled: @Sendable (SkillAgent) async -> Bool
  public var install: @Sendable (SkillAgent) async throws -> Void
  public var uninstall: @Sendable (SkillAgent) async throws -> Void

  public init(
    checkInstalled: @escaping @Sendable (SkillAgent) async -> Bool,
    install: @escaping @Sendable (SkillAgent) async throws -> Void,
    uninstall: @escaping @Sendable (SkillAgent) async throws -> Void
  ) {
    self.checkInstalled = checkInstalled
    self.install = install
    self.uninstall = uninstall
  }
}

extension CLISkillClient: DependencyKey {
  public static let liveValue = Self(
    checkInstalled: { CLISkillInstaller().isInstalled($0) },
    install: { try CLISkillInstaller().install($0) },
    uninstall: { try CLISkillInstaller().uninstall($0) },
  )
  public static let testValue = Self(
    checkInstalled: { _ in false },
    install: { _ in },
    uninstall: { _ in },
  )
}

public extension DependencyValues {
  var cliSkillClient: CLISkillClient {
    get { self[CLISkillClient.self] }
    set { self[CLISkillClient.self] = newValue }
  }
}
