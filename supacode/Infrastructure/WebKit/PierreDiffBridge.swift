import Foundation
import WebKit

enum PierreDiffTheme: String, Equatable {
  case light
  case dark
}

@MainActor
final class PierreDiffBridge {
  private weak var webView: WKWebView?
  private var isLoaded = false
  private var pendingPatch: String?
  private var currentTheme: PierreDiffTheme = .light
  private let logger = SupaLogger("PierreDiff")

  init(webView: WKWebView) {
    self.webView = webView
  }

  func loadPanel() {
    guard let webView else {
      return
    }
    guard
      let indexURL = Bundle.main.url(
        forResource: "index",
        withExtension: "html",
        subdirectory: "PierrePanel"
      )
    else {
      logger.warning("pierre panel index.html not found in bundle")
      return
    }
    webView.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
  }

  func didFinishNavigation() {
    isLoaded = true
    applyTheme()
    applyPendingPatch()
  }

  func setTheme(_ theme: PierreDiffTheme) {
    currentTheme = theme
    guard isLoaded else {
      return
    }
    applyTheme()
  }

  func renderPatch(_ patch: String) {
    pendingPatch = patch
    guard isLoaded else {
      return
    }
    applyPendingPatch()
  }

  func clear() {
    pendingPatch = nil
    guard isLoaded else {
      return
    }
    evaluateJavaScript("window.SupacodePierrePanel?.clear?.();")
  }

  private func applyTheme() {
    evaluateJavaScript("window.SupacodePierrePanel?.setTheme?.('\(currentTheme.rawValue)');")
  }

  private func applyPendingPatch() {
    guard let pendingPatch,
      let patchArgument = javascriptStringLiteral(pendingPatch)
    else {
      return
    }
    evaluateJavaScript("window.SupacodePierrePanel?.renderPatch?.(\(patchArgument), { diffStyle: 'split' });")
  }

  private func evaluateJavaScript(_ script: String) {
    webView?.evaluateJavaScript(script) { [logger] _, error in
      if let error {
        logger.warning("pierre panel script error: \(error.localizedDescription)")
      }
    }
  }

  private func javascriptStringLiteral(_ value: String) -> String? {
    guard
      let data = try? JSONSerialization.data(withJSONObject: [value]),
      var literal = String(data: data, encoding: .utf8),
      literal.count >= 2
    else {
      return nil
    }
    literal.removeFirst()
    literal.removeLast()
    return literal
  }
}
