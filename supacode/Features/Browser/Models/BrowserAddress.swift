import Foundation

nonisolated enum BrowserAddress {
  static let blank = URL(string: "about:blank")!

  static func isLoadable(_ url: URL) -> Bool {
    switch url.scheme?.lowercased() {
    case "http", "https", "about", "blob", "data": true
    default: false
    }
  }

  static func isWebLink(_ url: URL) -> Bool {
    ["http", "https"].contains(url.scheme?.lowercased()) && url.host() != nil
  }

  static func resolve(_ input: String) -> URL? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.lowercased() == blank.absoluteString {
      return blank
    }
    if let url = URL(string: trimmed), url.scheme != nil, trimmed.contains("://") {
      return isWebLink(url) ? url : nil
    }
    return hostURL(trimmed) ?? searchURL(trimmed)
  }

  static func display(_ url: URL?) -> String {
    guard let url, url != blank else { return "" }
    return url.absoluteString
  }

  private static func hostURL(_ text: String) -> URL? {
    guard !text.contains(where: \.isWhitespace) else { return nil }
    let authority = text.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
    let isBracketedIPv6 = authority.hasPrefix("[")
    let host = isBracketedIPv6 ? String(authority) : String(authority.prefix { $0 != ":" })
    guard !host.isEmpty else { return nil }
    let isLocal = isBracketedIPv6 || host == "localhost" || host.hasSuffix(".localhost") || isIPv4(host)
    let hasPort =
      !isBracketedIPv6 && authority.dropFirst(host.count).dropFirst().allSatisfy(\.isNumber)
      && authority.count > host.count + 1
    let isDomain = looksLikeDomain(host)
    guard isLocal || isDomain || (hasPort && isHostLabel(host)) else { return nil }
    let scheme = isDomain && !isLocal ? "https" : "http"
    guard let url = URL(string: "\(scheme)://\(text)"), url.host() != nil else { return nil }
    return url
  }

  private static func isIPv4(_ host: String) -> Bool {
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
  }

  private static func isHostLabel(_ host: String) -> Bool {
    host.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
  }

  private static func looksLikeDomain(_ host: String) -> Bool {
    let labels = host.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }), isHostLabel(host) else { return false }
    guard let last = labels.last else { return false }
    return last.count >= 2 && last.allSatisfy(\.isLetter)
  }

  private static func searchURL(_ query: String) -> URL? {
    var components = URLComponents(string: "https://www.google.com/search")
    components?.queryItems = [URLQueryItem(name: "q", value: query)]
    return components?.url
  }
}
