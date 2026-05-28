import Foundation

nonisolated enum Forge: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
  case github
  case gitlab

  static func detect(host: String) -> Forge? {
    let normalized = host.lowercased()
    if normalized.contains("github") {
      return .github
    }
    if normalized.contains("gitlab") {
      return .gitlab
    }
    return nil
  }
}
