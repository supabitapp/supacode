import Foundation

/// A forge-blind parse of a git remote URL: host, optional port, and the full
/// namespace path. Forge semantics (owner/repo pairs, forge detection) layer
/// on top of this; the parser itself knows nothing about any forge.
nonisolated struct GitRemote: Equatable, Sendable {
  let host: String
  let port: Int?
  let pathComponents: [String]
  let rawURL: String

  /// Full namespace path, matching `ForgeProjectRef.path`.
  var path: String {
    pathComponents.joined(separator: "/")
  }

  static func parse(_ remoteURL: String) -> GitRemote? {
    let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.contains("://") {
      return parseSchemed(trimmed)
    }
    return parseSCPStyle(trimmed)
  }

  private static let supportedSchemes: Set<String> = ["ssh", "https", "http", "git"]

  private static func parseSchemed(_ remoteURL: String) -> GitRemote? {
    guard
      let components = URLComponents(string: remoteURL),
      let scheme = components.scheme?.lowercased(),
      supportedSchemes.contains(scheme),
      let host = components.host?.lowercased(),
      !host.isEmpty
    else {
      return nil
    }
    let pathComponents = normalizedPathComponents(components.path)
    guard !pathComponents.isEmpty else { return nil }
    return GitRemote(host: host, port: components.port, pathComponents: pathComponents, rawURL: remoteURL)
  }

  /// `[user@]host:path`, the scheme-less form ssh accepts. Anything without a
  /// colon (local paths, relative submodule URLs) is not a remote we can name.
  private static func parseSCPStyle(_ remoteURL: String) -> GitRemote? {
    guard let colonIndex = remoteURL.firstIndex(of: ":") else { return nil }
    let hostPart = String(remoteURL[remoteURL.startIndex..<colonIndex])
    let pathPart = String(remoteURL[remoteURL.index(after: colonIndex)...])
    guard !hostPart.contains("/") else { return nil }
    let host: String
    if let atIndex = hostPart.lastIndex(of: "@") {
      host = String(hostPart[hostPart.index(after: atIndex)...]).lowercased()
    } else {
      host = hostPart.lowercased()
    }
    guard !host.isEmpty else { return nil }
    let pathComponents = normalizedPathComponents(pathPart)
    guard !pathComponents.isEmpty else { return nil }
    return GitRemote(host: host, port: nil, pathComponents: pathComponents, rawURL: remoteURL)
  }

  private static func normalizedPathComponents(_ path: String) -> [String] {
    var components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    if var last = components.last {
      if last.hasSuffix(".git") {
        last = String(last.dropLast(4))
      }
      if last.isEmpty {
        components.removeLast()
      } else {
        components[components.count - 1] = last
      }
    }
    return components
  }
}
