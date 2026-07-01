import Foundation
import Security
import SupacodeSettingsShared

enum GitHubDesktopOAuth {
  private static let clientID = "de0e3c7e9973e1c4dd77"
  private static let clientSecret = "1273305a5fc2737c2ca2911948ba24a9d961e2a3"
  private static let statePrefix = "supacode"
  private static let dotComAPIEndpoint = "https://api.github.com"
  private static let tokenService = "app.supabit.supacode.github-desktop-oauth"
  private static let logger = SupaLogger("GitHubDesktopOAuth")

  static func makeState(host: String) -> String {
    let endpoint = endpoint(for: host) ?? dotComAPIEndpoint
    let encodedHost = Data(endpoint.utf8)
      .base64EncodedString()
      .replacing("+", with: "-")
      .replacing("/", with: "_")
      .replacing("=", with: "")
    return "\(statePrefix).\(UUID().uuidString).\(encodedHost)"
  }

  static func host(fromState state: String) -> String? {
    endpoint(fromState: state).flatMap(htmlURL(forEndpoint:))
  }

  static func endpoint(fromState state: String) -> String? {
    let parts = state.split(separator: ".", maxSplits: 2).map(String.init)
    guard parts.count == 3, parts[0] == statePrefix else { return nil }

    var encoded = parts[2]
      .replacing("-", with: "+")
      .replacing("_", with: "/")
    let padding = (4 - encoded.count % 4) % 4
    encoded += String(repeating: "=", count: padding)

    guard
      let data = Data(base64Encoded: encoded),
      let endpoint = String(data: data, encoding: .utf8)
    else { return nil }
    return Self.endpoint(for: endpoint)
  }

  static func authorizationURL(host: String, state: String) -> URL? {
    guard
      let endpoint = endpoint(for: host),
      let htmlURL = htmlURL(forEndpoint: endpoint),
      var components = URLComponents(string: htmlURL)
    else { return nil }
    components.path = "/login/oauth/authorize"
    components.percentEncodedQuery = [
      "client_id=\(clientID)",
      "scope=repo%20user%20workflow",
      "state=\(percentEncode(state))",
    ].joined(separator: "&")
    return components.url
  }

  static func exchangeCode(_ code: String, state: String) async throws -> GitHubDesktopAccount {
    guard let endpoint = endpoint(fromState: state) else { throw GitHubDesktopOAuthError.invalidState }
    let token = try await requestOAuthToken(endpoint: endpoint, code: code)
    let account = try await fetchUser(endpoint: endpoint, token: token)
    storeToken(token, for: account)
    return account
  }

  static func signOut(_ account: GitHubDesktopAccount) async {
    guard let token = token(for: account) else { return }
    _ = await deleteToken(endpoint: account.endpoint, token: token)
    deleteStoredToken(for: account)
  }

  static func endpoint(for host: String) -> String? {
    let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
    guard
      let components = URLComponents(string: candidate),
      components.scheme?.lowercased() == "https",
      let host = components.host?.lowercased(),
      !host.isEmpty
    else { return nil }
    if host == "github.com" || host == "api.github.com" {
      return dotComAPIEndpoint
    }
    if host.hasSuffix(".ghe.com") {
      let apiHost = host.hasPrefix("api.") ? host : "api.\(host)"
      return "https://\(apiHost)/"
    }
    return "https://\(host)/api/v3"
  }

  private static func requestOAuthToken(endpoint: String, code: String) async throws -> String {
    guard
      let htmlURL = htmlURL(forEndpoint: endpoint),
      var components = URLComponents(string: htmlURL)
    else {
      throw GitHubDesktopOAuthError.invalidHost
    }
    components.path = "/login/oauth/access_token"
    guard let url = components.url else { throw GitHubDesktopOAuthError.invalidHost }

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
    return token.accessToken
  }

  private static func fetchUser(endpoint: String, token: String) async throws -> GitHubDesktopAccount {
    guard var components = URLComponents(string: endpoint) else {
      throw GitHubDesktopOAuthError.invalidHost
    }
    components.path = components.path.hasSuffix("/") ? "\(components.path)user" : "\(components.path)/user"
    guard let url = components.url else { throw GitHubDesktopOAuthError.invalidHost }

    var request = URLRequest(url: url)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw GitHubDesktopOAuthError.fetchUserFailed
    }
    let user = try JSONDecoder().decode(UserResponse.self, from: data)
    return GitHubDesktopAccount(
      endpoint: endpoint,
      login: user.login,
      name: user.name ?? user.login,
      avatarURL: user.avatarURL,
      id: user.id
    )
  }

  private static func deleteToken(endpoint: String, token: String) async -> Bool {
    guard var components = URLComponents(string: endpoint) else { return false }
    components.path =
      components.path.hasSuffix("/")
      ? "\(components.path)applications/\(clientID)/token"
      : "\(components.path)/applications/\(clientID)/token"
    guard let url = components.url else { return false }

    var request = URLRequest(url: url)
    request.httpMethod = "DELETE"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(
      "Basic \(Data("\(clientID):\(clientSecret)".utf8).base64EncodedString())",
      forHTTPHeaderField: "Authorization"
    )
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["access_token": token])

    do {
      let (_, response) = try await URLSession.shared.data(for: request)
      return (response as? HTTPURLResponse)?.statusCode == 204
    } catch {
      logger.warning("Failed to revoke GitHub Desktop OAuth token for \(endpoint): \(error.localizedDescription)")
      return false
    }
  }

  private static func htmlURL(forEndpoint endpoint: String) -> String? {
    if endpoint == dotComAPIEndpoint {
      return "https://github.com"
    }
    guard var components = URLComponents(string: endpoint), let host = components.host else { return nil }
    if host.hasPrefix("api."), host.hasSuffix(".ghe.com") {
      components.host = String(host.dropFirst("api.".count))
    }
    components.path = ""
    components.query = nil
    components.fragment = nil
    guard let value = components.url?.absoluteString else { return nil }
    return value.hasSuffix("/") ? String(value.dropLast()) : value
  }

  private static func percentEncode(_ value: String) -> String {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&=+")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
  }

  private static func keychainAccount(for account: GitHubDesktopAccount) -> String {
    account.endpoint
  }

  private static func storeToken(_ token: String, for account: GitHubDesktopAccount) {
    let keychainAccount = keychainAccount(for: account)
    let data = Data(token.utf8)
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: tokenService,
      kSecAttrAccount: keychainAccount,
    ]
    let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
    if status == errSecSuccess { return }
    var addQuery = query
    addQuery[kSecValueData] = data
    let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
    if addStatus != errSecSuccess {
      logger.warning("Failed to store GitHub Desktop OAuth token in Keychain: \(addStatus)")
    }
  }

  private static func token(for account: GitHubDesktopAccount) -> String? {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: tokenService,
      kSecAttrAccount: keychainAccount(for: account),
      kSecReturnData: true,
      kSecMatchLimit: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static func deleteStoredToken(for account: GitHubDesktopAccount) {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: tokenService,
      kSecAttrAccount: keychainAccount(for: account),
    ]
    SecItemDelete(query as CFDictionary)
  }
}

enum GitHubDesktopOAuthError: Error, LocalizedError {
  case invalidHost
  case invalidState
  case exchangeFailed
  case fetchUserFailed

  var errorDescription: String? {
    switch self {
    case .invalidHost:
      "Invalid GitHub host."
    case .invalidState:
      "Invalid GitHub Desktop OAuth state."
    case .exchangeFailed:
      "GitHub rejected the GitHub Desktop OAuth callback."
    case .fetchUserFailed:
      "GitHub Desktop authorization completed, but Supacode could not read the account."
    }
  }
}

private struct TokenResponse: Decodable {
  var accessToken: String

  private enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
  }
}

private struct UserResponse: Decodable {
  var login: String
  var name: String?
  var avatarURL: String?
  var id: Int

  private enum CodingKeys: String, CodingKey {
    case login
    case name
    case avatarURL = "avatar_url"
    case id
  }
}
