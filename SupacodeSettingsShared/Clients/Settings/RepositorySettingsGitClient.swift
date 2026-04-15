import ComposableArchitecture
import Foundation

public nonisolated struct RepositorySettingsGitClient: Sendable {
  public var isBareRepository: @Sendable (URL) async throws -> Bool
  public var branchRefs: @Sendable (URL) async throws -> [String]
  public var automaticWorktreeBaseRef: @Sendable (URL) async -> String?

  public init(
    isBareRepository: @escaping @Sendable (URL) async throws -> Bool,
    branchRefs: @escaping @Sendable (URL) async throws -> [String],
    automaticWorktreeBaseRef: @escaping @Sendable (URL) async -> String?
  ) {
    self.isBareRepository = isBareRepository
    self.branchRefs = branchRefs
    self.automaticWorktreeBaseRef = automaticWorktreeBaseRef
  }
}

extension RepositorySettingsGitClient: DependencyKey {
  public static let liveValue = RepositorySettingsGitClient(
    isBareRepository: { try await GitReferenceQueries().isBareRepository(for: $0) },
    branchRefs: { try await GitReferenceQueries().branchRefs(for: $0) },
    automaticWorktreeBaseRef: { await GitReferenceQueries().automaticWorktreeBaseRef(for: $0) }
  )

  public static let testValue = RepositorySettingsGitClient(
    isBareRepository: { _ in false },
    branchRefs: { _ in [] },
    automaticWorktreeBaseRef: { _ in nil }
  )
}

public extension DependencyValues {
  var repositorySettingsGitClient: RepositorySettingsGitClient {
    get { self[RepositorySettingsGitClient.self] }
    set { self[RepositorySettingsGitClient.self] = newValue }
  }
}
