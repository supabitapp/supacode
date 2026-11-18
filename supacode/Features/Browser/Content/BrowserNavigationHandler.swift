import AppKit
import SupacodeSettingsShared
import WebKit

final class BrowserNavigationHandler: NSObject, WKNavigationDelegate, WKUIDelegate {
  nonisolated enum NavigationDecision: Equatable, Sendable {
    case load
    case openInNewTab
    case askBeforeLeavingForAnotherApp
    case cancel
  }

  private static let logger = SupaLogger("Browser")

  private struct PendingDialog {
    var dialog: BrowserPageDialog
    var resolve: (BrowserDialogAnswer) -> Void
  }

  var failedURL: URL?
  var documentChanged: (() -> Void)?
  var dialogChanged: ((BrowserPageDialog?) -> Void)?
  private var pendingDialog: PendingDialog?
  private var isLoadingErrorPage = false
  private var isAskingToLeave = false
  private let openInNewTab: (URL) -> Void
  private let closeRequested: () -> Void

  init(openInNewTab: @escaping (URL) -> Void, closeRequested: @escaping () -> Void) {
    self.openInNewTab = openInNewTab
    self.closeRequested = closeRequested
  }

  nonisolated deinit {}

  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
  ) {
    decisionHandler(policy(for: navigationAction, in: webView))
  }

  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationResponse: WKNavigationResponse,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
  ) {
    decisionHandler(policy(for: navigationResponse))
  }

  nonisolated static func navigationDecision(
    for url: URL?,
    isLinkActivation: Bool,
    holdsCommand: Bool
  ) -> NavigationDecision {
    guard let url else { return .cancel }
    if BrowserAddress.isLoadable(url) {
      return isLinkActivation && holdsCommand ? .openInNewTab : .load
    }
    guard isLinkActivation, !url.isFileURL else { return .cancel }
    return .askBeforeLeavingForAnotherApp
  }

  private func policy(for navigationAction: WKNavigationAction, in webView: WKWebView) -> WKNavigationActionPolicy {
    let url = navigationAction.request.url
    let decision = Self.navigationDecision(
      for: url,
      isLinkActivation: navigationAction.navigationType == .linkActivated,
      holdsCommand: navigationAction.modifierFlags.contains(.command)
    )
    switch decision {
    case .load:
      return .allow
    case .openInNewTab:
      url.map(openInNewTab)
      return .cancel
    case .askBeforeLeavingForAnotherApp:
      url.map { askBeforeLeaving(for: $0, from: webView) }
      return .cancel
    case .cancel:
      return .cancel
    }
  }

  private func askBeforeLeaving(for url: URL, from webView: WKWebView) {
    guard !isAskingToLeave, let window = webView.window,
      let application = NSWorkspace.shared.urlForApplication(toOpen: url)
    else { return }
    isAskingToLeave = true
    let alert = NSAlert()
    alert.messageText = "Open this link in \(application.deletingPathExtension().lastPathComponent)?"
    alert.informativeText = String(url.absoluteString.prefix(300))
    alert.addButton(withTitle: "Open").keyEquivalent = ""
    alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) { [weak self] response in
      self?.isAskingToLeave = false
      guard response == .alertFirstButtonReturn else { return }
      NSWorkspace.shared.open(url)
    }
  }

  private func policy(for navigationResponse: WKNavigationResponse) -> WKNavigationResponsePolicy {
    guard navigationResponse.isForMainFrame, !navigationResponse.canShowMIMEType,
      let url = navigationResponse.response.url
    else { return .allow }
    NSWorkspace.shared.open(url)
    return .cancel
  }

  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    guard !isLoadingErrorPage else {
      isLoadingErrorPage = false
      return
    }
    failedURL = nil
  }

  func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: any Error
  ) {
    let nsError = error as NSError
    let isInterruption =
      (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
      || (nsError.domain == "WebKitErrorDomain" && nsError.code == 102)
    guard !isInterruption else { return }
    let url = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? webView.url
    Self.logger.info("Navigation failed for \(url?.absoluteString ?? "unknown"): \(nsError.localizedDescription)")
    failedURL = url
    isLoadingErrorPage = true
    webView.loadHTMLString(
      BrowserErrorPage.html(message: nsError.localizedDescription, url: url),
      baseURL: url
    )
  }

  func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    documentChanged?()
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    Self.logger.warning("Web content process terminated; reloading.")
    documentChanged?()
    webView.reload()
  }

  func webView(
    _ webView: WKWebView,
    createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction,
    windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    if let url = navigationAction.request.url, BrowserAddress.isLoadable(url) {
      openInNewTab(url)
    }
    return nil
  }

  func webViewDidClose(_ webView: WKWebView) {
    closeRequested()
  }

  func webView(
    _ webView: WKWebView,
    runJavaScriptAlertPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo
  ) async {
    _ = await ask(BrowserPageDialog(kind: .alert, message: message))
  }

  func webView(
    _ webView: WKWebView,
    runJavaScriptConfirmPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo
  ) async -> Bool {
    await ask(BrowserPageDialog(kind: .confirm, message: message)) != .dismiss
  }

  func webView(
    _ webView: WKWebView,
    runJavaScriptTextInputPanelWithPrompt prompt: String,
    defaultText: String?,
    initiatedByFrame frame: WKFrameInfo
  ) async -> String? {
    let dialog = BrowserPageDialog(kind: .prompt, message: prompt, defaultText: defaultText)
    switch await ask(dialog) {
    case .accept(let text): return text ?? defaultText ?? ""
    case .dismiss: return nil
    }
  }

  private func ask(_ dialog: BrowserPageDialog) async -> BrowserDialogAnswer {
    await withCheckedContinuation { continuation in
      pendingDialog = PendingDialog(dialog: dialog) { continuation.resume(returning: $0) }
      dialogChanged?(dialog)
    }
  }

  @discardableResult
  func answerDialog(_ answer: BrowserDialogAnswer) -> BrowserPageDialog? {
    guard let pending = pendingDialog else { return nil }
    pendingDialog = nil
    dialogChanged?(nil)
    pending.resolve(answer)
    return pending.dialog
  }

  func webView(
    _ webView: WKWebView,
    runOpenPanelWith parameters: WKOpenPanelParameters,
    initiatedByFrame frame: WKFrameInfo
  ) async -> [URL]? {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = parameters.allowsMultipleSelection
    panel.canChooseDirectories = parameters.allowsDirectories
    panel.canChooseFiles = true
    guard let window = webView.window else {
      return panel.runModal() == .OK ? panel.urls : nil
    }
    return await panel.beginSheetModal(for: window) == .OK ? panel.urls : nil
  }

}

nonisolated enum BrowserErrorPage {
  static func html(message: String, url: URL?) -> String {
    let address = escaped(url?.absoluteString ?? "")
    return """
      <!doctype html>
      <html>
      <head>
      <meta charset="utf-8">
      <meta name="color-scheme" content="light dark">
      <title>Page failed to load</title>
      <style>
      body { font: -apple-system-body; margin: 15vh auto; max-width: 32rem; padding: 0 1.5rem; }
      h1 { font: -apple-system-title2; }
      p { color: GrayText; overflow-wrap: anywhere; }
      </style>
      </head>
      <body>
      <h1>This page failed to load</h1>
      <p>\(escaped(message))</p>
      <p>\(address)</p>
      </body>
      </html>
      """
  }

  private static func escaped(_ text: String) -> String {
    text
      .replacing("&", with: "&amp;")
      .replacing("<", with: "&lt;")
      .replacing(">", with: "&gt;")
      .replacing("\"", with: "&quot;")
  }
}
