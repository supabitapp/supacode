import AppKit
import Foundation
import Testing
import WebKit

@testable import supacode

@MainActor
struct BrowserContentTests {
  private static let pageURL = URL(string: "data:text/html,<title>Fixture</title><p>fixture</p>")!

  private static func makeWebView() -> BrowserWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    return BrowserWebView(frame: .zero, configuration: configuration)
  }

  private static func makeContent(
    url: URL? = nil,
    callbacks: BrowserContentCallbacks = BrowserContentCallbacks()
  ) -> BrowserContent {
    BrowserContent(
      id: ContentID(),
      initialState: BrowserContentState(url: url),
      callbacks: callbacks,
      makeWebView: makeWebView
    )
  }

  @Test func hasNoRendererUntilTheSessionStarts() {
    let content = Self.makeContent(url: Self.pageURL)
    #expect(content.kind == .browser)
    #expect(content.renderer == nil)
    #expect(!content.isHibernatable)
    #expect(content.snapshot().state == .browser(BrowserContentState(url: Self.pageURL)))
  }

  @Test func startingTheSessionMountsOneWebView() {
    let content = Self.makeContent(url: Self.pageURL)
    content.startSession(at: .fallback)
    let renderer = content.renderer
    #expect(renderer is BrowserWebView)
    #expect(content.isHibernatable)
    content.startSession(at: .fallback)
    #expect(content.renderer === renderer)
    content.tearDown()
  }

  @Test func hibernatingDropsTheWebViewAndKeepsThePage() {
    let content = Self.makeContent(url: Self.pageURL)
    content.startSession(at: .fallback)
    content.hibernate()
    #expect(content.renderer == nil)
    #expect(!content.isHibernatable)
    #expect(content.snapshot().state == .browser(BrowserContentState(url: Self.pageURL)))
  }

  @Test func wakingAfterHibernationMountsAFreshWebView() {
    let content = Self.makeContent(url: Self.pageURL)
    content.startSession(at: .fallback)
    let first = content.renderer
    content.hibernate()
    content.startSession(at: .fallback)
    #expect(content.renderer != nil)
    #expect(content.renderer !== first)
    content.tearDown()
  }

  @Test func tearingDownReleasesTheWebView() {
    let content = Self.makeContent(url: Self.pageURL)
    content.startSession(at: .fallback)
    content.tearDown()
    #expect(content.renderer == nil)
  }

  @Test func navigatingRecordsTheResolvedAddress() {
    let content = Self.makeContent()
    content.startSession(at: .fallback)
    content.navigate(to: "localhost:3000/app")
    let expected = URL(string: "http://localhost:3000/app")
    #expect(content.page.url == expected)
    #expect(content.snapshot().state == .browser(BrowserContentState(url: expected)))
    content.tearDown()
  }

  @Test func navigatingToBlankInputKeepsThePage() {
    let content = Self.makeContent(url: Self.pageURL)
    content.startSession(at: .fallback)
    content.navigate(to: "   ")
    #expect(content.page.url == Self.pageURL)
    content.tearDown()
  }

  private static func mount(_ content: BrowserContent) throws -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
      styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView?.addSubview(try #require(content.renderer))
    return window
  }

  @Test func aBlankTabIsTitledNewTabAndTakesFocusInItsAddressField() throws {
    let content = Self.makeContent()
    content.startSession(at: .fallback)
    let window = try Self.mount(content)
    #expect(content.page.reportedTitle == "New Tab")
    #expect(!content.page.addressFocusRequested)
    content.focus()
    #expect(content.page.addressFocusRequested)
    #expect(content.holdsKeyboardFocus)
    #expect(window.firstResponder !== content.renderer)
    content.tearDown()
    window.close()
  }

  @Test func aLoadedTabTakesFocusInThePage() throws {
    let content = Self.makeContent(url: Self.pageURL)
    content.startSession(at: .fallback)
    let window = try Self.mount(content)
    #expect(!content.holdsKeyboardFocus)
    content.focus()
    #expect(window.firstResponder === content.renderer)
    #expect(content.holdsKeyboardFocus)
    #expect(!content.page.addressFocusRequested)
    content.tearDown()
    window.close()
  }

  private static func keyDown(_ characters: String, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
    try #require(
      NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: 0
      )
    )
  }

  @Test func aFocusedPageClaimsItsOwnChordsAndLeavesTheRest() throws {
    let content = Self.makeContent(url: Self.pageURL)
    content.startSession(at: .fallback)
    let window = try Self.mount(content)
    let reload = try Self.keyDown("r", modifiers: .command)
    let newTerminalTab = try Self.keyDown("t", modifiers: .command)

    #expect(!content.claimsKeyEquivalent(reload))
    content.focus()
    #expect(content.claimsKeyEquivalent(reload))
    #expect(!content.claimsKeyEquivalent(newTerminalTab))

    content.tearDown()
    window.close()
  }

  @Test func theAddressKeyCommandRequestsAddressFocus() {
    let content = Self.makeContent(url: Self.pageURL)
    content.startSession(at: .fallback)
    content.perform(.focusAddress)
    #expect(content.page.addressFocusRequested)
    content.tearDown()
  }

  @Test func zoomKeyCommandsStayWithinBounds() throws {
    let content = Self.makeContent(url: Self.pageURL)
    content.startSession(at: .fallback)
    let webView = try #require(content.renderer as? BrowserWebView)
    for _ in 0..<40 { content.perform(.zoomIn) }
    #expect(webView.pageZoom == 3)
    for _ in 0..<40 { content.perform(.zoomOut) }
    #expect(webView.pageZoom == 0.5)
    content.perform(.resetZoom)
    #expect(webView.pageZoom == 1)
    content.tearDown()
  }

  @Test func reportedTitlePrefersThePageTitleThenTheHost() {
    let page = BrowserPageState()
    #expect(page.reportedTitle == "New Tab")
    page.url = URL(string: "https://example.com/docs")
    #expect(page.reportedTitle == "example.com")
    page.title = "Docs"
    #expect(page.reportedTitle == "Docs")
    page.title = ""
    #expect(page.reportedTitle == "example.com")
  }

  @Test(arguments: [
    ("l", BrowserKeyCommand.focusAddress),
    ("r", .reload),
    ("[", .goBack),
    ("]", .goForward),
    ("=", .zoomIn),
    ("-", .zoomOut),
    ("0", .resetZoom),
  ])
  func mapsCommandChordsToBrowserCommands(characters: String, expected: BrowserKeyCommand) {
    #expect(BrowserKeyCommand(characters: characters, modifiers: .command) == expected)
  }

  @Test func ignoresChordsThatAreNotPlainCommand() {
    #expect(BrowserKeyCommand(characters: "r", modifiers: [.command, .shift]) == nil)
    #expect(BrowserKeyCommand(characters: "r", modifiers: [.command, .option]) == nil)
    #expect(BrowserKeyCommand(characters: "r", modifiers: []) == nil)
    #expect(BrowserKeyCommand(characters: "t", modifiers: .command) == nil)
    #expect(BrowserKeyCommand(characters: nil, modifiers: .command) == nil)
  }

  @Test func errorPageEscapesTheMessageAndAddress() {
    let html = BrowserErrorPage.html(
      message: "<script>alert(1)</script>",
      url: URL(string: "http://localhost:1/?a=%3Cb%3E&c=\"d\"")
    )
    #expect(!html.contains("<script>alert(1)</script>"))
    #expect(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
  }
}
