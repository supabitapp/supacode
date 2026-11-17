import Foundation
import Testing

@testable import supacode

struct BrowserAddressTests {
  @Test(arguments: [
    ("https://example.com/docs?q=1", "https://example.com/docs?q=1"),
    ("http://example.com", "http://example.com"),
    ("example.com", "https://example.com"),
    ("example.com/path#top", "https://example.com/path#top"),
    ("sub.example.co.uk:8443/x", "https://sub.example.co.uk:8443/x"),
    ("localhost", "http://localhost"),
    ("localhost:3000", "http://localhost:3000"),
    ("localhost:3000/app?tab=1", "http://localhost:3000/app?tab=1"),
    ("app.localhost:5173", "http://app.localhost:5173"),
    ("127.0.0.1:8080", "http://127.0.0.1:8080"),
    ("192.168.1.20", "http://192.168.1.20"),
    ("[::1]:3000", "http://[::1]:3000"),
    ("devbox:9000", "http://devbox:9000"),
    ("  example.com  ", "https://example.com"),
    ("about:blank", "about:blank"),
  ])
  func resolvesAddresses(input: String, expected: String) {
    #expect(BrowserAddress.resolve(input)?.absoluteString == expected)
  }

  @Test(arguments: ["swift concurrency", "hello", "what is 1.5", "readme.m d"])
  func searchesForTextThatIsNotAnAddress(input: String) throws {
    let url = try #require(BrowserAddress.resolve(input))
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.host == "www.google.com")
    #expect(components.path == "/search")
    #expect(components.queryItems == [URLQueryItem(name: "q", value: input)])
  }

  @Test(arguments: ["", "   ", "file:///etc/passwd", "ftp://example.com/file", "javascript://alert(1)"])
  func refusesBlankAndNonWebSchemes(input: String) {
    #expect(BrowserAddress.resolve(input) == nil)
  }

  @Test func displaysNothingForBlankPages() {
    #expect(BrowserAddress.display(nil) == "")
    #expect(BrowserAddress.display(BrowserAddress.blank) == "")
    #expect(BrowserAddress.display(URL(string: "http://localhost:3000/")) == "http://localhost:3000/")
  }

  @Test(arguments: [
    ("https://example.com", true),
    ("http://localhost:3000", true),
    ("about:blank", true),
    ("mailto:someone@example.com", false),
    ("slack://open", false),
    ("file:///tmp/index.html", false),
  ])
  func loadsOnlyWebSchemesInPlace(input: String, expected: Bool) throws {
    #expect(BrowserAddress.isLoadable(try #require(URL(string: input))) == expected)
  }

  @Test(arguments: [
    ("https://example.com/a", true),
    ("http://localhost:8765/second.html", true),
    ("file:///tmp/output.txt", false),
    ("mailto:someone@example.com", false),
    ("about:blank", false),
  ])
  func routesOnlyWebLinksToBrowserTabs(input: String, expected: Bool) throws {
    #expect(BrowserAddress.isWebLink(try #require(URL(string: input))) == expected)
  }
}
