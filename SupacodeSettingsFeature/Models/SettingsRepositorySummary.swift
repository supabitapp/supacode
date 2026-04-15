import Foundation

public struct SettingsRepositorySummary: Equatable, Hashable, Sendable {
  public var id: String
  public var name: String

  public var rootURL: URL {
    URL(fileURLWithPath: id).standardizedFileURL
  }

  public init(id: String, name: String) {
    self.id = id
    self.name = name
  }
}
