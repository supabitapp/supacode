import Foundation

public struct SettingsRepositorySummary: Equatable, Hashable, Sendable {
  public var id: String
  public var name: String
  public var isGitRepository: Bool

  public var rootURL: URL {
    URL(fileURLWithPath: id).standardizedFileURL
  }

  public init(id: String, name: String, isGitRepository: Bool = true) {
    self.id = id
    self.name = name
    self.isGitRepository = isGitRepository
  }
}
