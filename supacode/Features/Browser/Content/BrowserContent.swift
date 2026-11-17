import AppKit
import SupacodeSettingsShared
import SwiftUI
import WebKit

@Observable
final class BrowserPageState: TabChrome {
  var url: URL?
  var title: String?
  var isLoading = false
  var loadProgress: Double = 0
  var canGoBack = false
  var canGoForward = false
  var addressFocusRequested = false
  @ObservationIgnored var isAddressFocused = false

  nonisolated deinit {}

  var accessory: AnyView? { nil }
  var isWorking: Bool { isLoading }
  var progress: TerminalTabProgressDisplay? { nil }
  var isReadOnly: Bool { false }

  var reportedTitle: String? {
    if let title, !title.isEmpty { return title }
    if let host = url?.host(), !host.isEmpty { return host }
    return "New Tab"
  }
}

struct BrowserContentCallbacks {
  var focused: () -> Void = {}
  var stateChanged: () -> Void = {}
  var openInNewTab: (URL) -> Void = { _ in }
  var closeRequested: () -> Void = {}
  var mayClaimFocus: (NSWindow) -> Bool = { _ in false }
  var attached: () -> Void = {}
}

final class BrowserContent: TabContent, TabContentToolbar {
  let id: ContentID
  let kind: ContentKind = .browser
  let page = BrowserPageState()

  private let callbacks: BrowserContentCallbacks
  private let makeWebView: @MainActor () -> BrowserWebView
  private var webView: BrowserWebView?
  private var navigation: BrowserNavigationHandler?
  private var observations: [NSKeyValueObservation] = []
  private var retainedInteractionState: Any?
  private var pendingFocusClaim: Task<Void, Never>?

  init(
    id: ContentID,
    initialState: BrowserContentState,
    callbacks: BrowserContentCallbacks,
    makeWebView: @escaping @MainActor () -> BrowserWebView = BrowserContent.makeDefaultWebView
  ) {
    self.id = id
    self.callbacks = callbacks
    self.makeWebView = makeWebView
    page.url = initialState.url
  }

  nonisolated deinit {}

  var renderer: NSView? { webView }
  var chrome: (any TabChrome)? { page }
  var toolbar: (any TabContentToolbar)? { self }
  var view: AnyView? { AnyView(BrowserToolbarView(page: page, content: self).id(id)) }
  var isHibernatable: Bool { webView != nil }

  func startSession(at geometry: ContentGeometry) {
    guard webView == nil else { return }
    let webView = makeWebView()
    let navigation = BrowserNavigationHandler(
      openInNewTab: callbacks.openInNewTab,
      closeRequested: callbacks.closeRequested
    )
    webView.navigationDelegate = navigation
    webView.uiDelegate = navigation
    webView.onFocus = callbacks.focused
    webView.onKeyCommand = { [weak self] in self?.perform($0) }
    webView.onAttach = { [weak self] in self?.claimFocusAfterAttach() }
    webView.holdsBrowserFocus = { [weak self] in self?.holdsKeyboardFocus ?? false }
    self.webView = webView
    self.navigation = navigation
    observe(webView)
    if let retainedInteractionState {
      webView.interactionState = retainedInteractionState
      self.retainedInteractionState = nil
    } else if let url = page.url, url != BrowserAddress.blank {
      webView.load(URLRequest(url: url))
    }
  }

  func hibernate() {
    guard let webView else { return }
    retainedInteractionState = webView.interactionState
    releaseWebView()
  }

  func tearDown() {
    releaseWebView()
    retainedInteractionState = nil
  }

  func snapshot() -> ContentSnapshot {
    ContentSnapshot(id: id, state: .browser(BrowserContentState(url: page.url)))
  }

  var holdsKeyboardFocus: Bool {
    if page.isAddressFocused { return true }
    guard let webView, let responder = webView.window?.firstResponder as? NSView else { return false }
    return responder === webView || responder.isDescendant(of: webView)
  }

  func claimsKeyEquivalent(_ event: NSEvent) -> Bool {
    holdsKeyboardFocus && BrowserKeyCommand(event: event) != nil
  }

  func focus() {
    guard let webView, let window = webView.window else { return }
    guard !showsBlankPage else {
      page.addressFocusRequested = true
      return
    }
    window.makeFirstResponder(webView)
  }

  private var showsBlankPage: Bool {
    guard let url = page.url else { return true }
    return url == BrowserAddress.blank
  }

  func navigate(to input: String) {
    guard let url = BrowserAddress.resolve(input) else { return }
    load(url)
  }

  func load(_ url: URL) {
    page.url = url
    guard let webView else { return }
    navigation?.failedURL = nil
    webView.load(URLRequest(url: url))
    focus()
  }

  func perform(_ command: BrowserKeyCommand) {
    guard let webView else { return }
    switch command {
    case .focusAddress:
      page.addressFocusRequested = true
    case .reload:
      reload()
    case .goBack:
      webView.goBack()
    case .goForward:
      webView.goForward()
    case .zoomIn:
      webView.pageZoom = min(webView.pageZoom + 0.1, 3)
    case .zoomOut:
      webView.pageZoom = max(webView.pageZoom - 0.1, 0.5)
    case .resetZoom:
      webView.pageZoom = 1
    }
  }

  func reloadOrStop() {
    guard let webView else { return }
    if webView.isLoading {
      webView.stopLoading()
    } else {
      reload()
    }
  }

  private func reload() {
    guard let webView else { return }
    if let failedURL = navigation?.failedURL {
      navigation?.failedURL = nil
      webView.load(URLRequest(url: failedURL))
    } else {
      webView.reload()
    }
  }

  func addressFocusChanged(_ focused: Bool) {
    page.isAddressFocused = focused
    if focused {
      callbacks.focused()
    }
  }

  // AppKit does not promote a re-attached view to first responder, and an
  // immediate claim is unreliable while SwiftUI is still mounting, so the
  // claim runs on the next tick.
  private func claimFocusAfterAttach() {
    pendingFocusClaim?.cancel()
    pendingFocusClaim = Task { [weak self] in
      guard let self, !Task.isCancelled else { return }
      self.callbacks.attached()
      guard let window = self.webView?.window, !self.holdsKeyboardFocus, self.callbacks.mayClaimFocus(window)
      else { return }
      self.focus()
    }
  }

  private func releaseWebView() {
    pendingFocusClaim?.cancel()
    pendingFocusClaim = nil
    observations.forEach { $0.invalidate() }
    observations = []
    webView?.stopLoading()
    webView?.navigationDelegate = nil
    webView?.uiDelegate = nil
    webView?.removeFromSuperview()
    webView = nil
    navigation = nil
    page.isLoading = false
    page.canGoBack = false
    page.canGoForward = false
  }

  private func observe(_ webView: BrowserWebView) {
    observations = [
      webView.observe(\.url, options: [.initial, .new]) { [weak self] webView, _ in
        MainActor.assumeIsolated { self?.urlChanged(webView.url) }
      },
      webView.observe(\.title, options: [.initial, .new]) { [weak self] webView, _ in
        MainActor.assumeIsolated { self?.titleChanged(webView.title) }
      },
      webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] webView, _ in
        MainActor.assumeIsolated { self?.page.isLoading = webView.isLoading }
      },
      webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] webView, _ in
        MainActor.assumeIsolated { self?.page.loadProgress = webView.estimatedProgress }
      },
      webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] webView, _ in
        MainActor.assumeIsolated { self?.page.canGoBack = webView.canGoBack }
      },
      webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] webView, _ in
        MainActor.assumeIsolated { self?.page.canGoForward = webView.canGoForward }
      },
    ]
  }

  private func urlChanged(_ url: URL?) {
    let shown = navigation?.failedURL ?? url
    guard let shown, page.url != shown else { return }
    page.url = shown
    callbacks.stateChanged()
  }

  private func titleChanged(_ title: String?) {
    guard page.title != title else { return }
    page.title = title
    callbacks.stateChanged()
  }

  static func makeDefaultWebView() -> BrowserWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .default()
    configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
    configuration.preferences.isElementFullscreenEnabled = true
    let webView = BrowserWebView(frame: .zero, configuration: configuration)
    webView.allowsBackForwardNavigationGestures = true
    webView.allowsMagnification = true
    webView.isInspectable = true
    return webView
  }
}
