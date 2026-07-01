import Foundation

enum GitHubDesktopOAuth {
  private static let clientID = "de0e3c7e9973e1c4dd77"
  private static let clientSecret = "1273305a5fc2737c2ca2911948ba24a9d961e2a3"
  private static let statePrefix = "supacode"

  static func makeState(host: String) -> String {
    let normalizedHost = normalizedHost(host) ?? "https://github.com"
    let encodedHost = Data(normalizedHost.utf8)
      .base64EncodedString()
      .replacing("+", with: "-")
      .replacing("/", with: "_")
      .replacing("=", with: "")
    return "\(statePrefix).\(UUID().uuidString).\(encodedHost)"
  }

  static func host(fromState state: String) -> String? {
    let parts = state.split(separator: ".", maxSplits: 2).map(String.init)
    guard parts.count == 3, parts[0] == statePrefix else { return nil }

    var encoded = parts[2]
      .replacing("-", with: "+")
      .replacing("_", with: "/")
    let padding = (4 - encoded.count % 4) % 4
    encoded += String(repeating: "=", count: padding)

    guard
      let data = Data(base64Encoded: encoded),
      let host = String(data: data, encoding: .utf8)
    else { return nil }
    return host
  }

  static func authorizationURL(host: String, state: String) -> URL? {
    guard var components = components(host: host, path: "/login/oauth/authorize") else { return nil }
    components.percentEncodedQuery = [
      "client_id=\(clientID)",
      "scope=repo%20user%20workflow",
      "state=\(percentEncode(state))",
    ].joined(separator: "&")
    return components.url
  }

  static func exchangeCode(_ code: String, state: String) async throws -> String {
    guard let host = host(fromState: state) else { throw GitHubDesktopOAuthError.invalidState }
    guard let url = components(host: host, path: "/login/oauth/access_token")?.url else {
      throw GitHubDesktopOAuthError.invalidHost
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "client_id": clientID,
      "client_secret": clientSecret,
      "code": code,
    ])

    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw GitHubDesktopOAuthError.exchangeFailed
    }
    let token = try JSONDecoder().decode(TokenResponse.self, from: data)
    guard !token.accessToken.isEmpty else { throw GitHubDesktopOAuthError.exchangeFailed }
    return host
  }

  private static func components(host: String, path: String) -> URLComponents? {
    guard
      let normalizedHost = normalizedHost(host),
      var components = URLComponents(string: normalizedHost),
      components.host != nil
    else { return nil }
    components.path = path
    components.query = nil
    components.fragment = nil
    return components
  }

  private static func normalizedHost(_ host: String) -> String? {
    let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    var components = URLComponents(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)")
    guard components?.host != nil else { return nil }
    components?.path = ""
    components?.query = nil
    components?.fragment = nil
    return components?.url?.absoluteString
  }

  private static func percentEncode(_ value: String) -> String {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&=+")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
  }
}

enum GitHubDesktopOAuthError: Error, LocalizedError {
  case invalidHost
  case invalidState
  case exchangeFailed

  var errorDescription: String? {
    switch self {
    case .invalidHost:
      "Invalid GitHub host."
    case .invalidState:
      "Invalid GitHub Desktop OAuth state."
    case .exchangeFailed:
      "GitHub rejected the GitHub Desktop OAuth callback."
    }
  }
}

private struct TokenResponse: Decodable {
  var accessToken: String

  private enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
  }
}
