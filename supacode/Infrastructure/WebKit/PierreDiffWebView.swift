import SwiftUI
import WebKit

struct PierreDiffWebView: NSViewRepresentable {
  let patch: String
  let theme: PierreDiffTheme

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = context.coordinator
    webView.setValue(false, forKey: "drawsBackground")
    context.coordinator.attach(webView)
    return webView
  }

  func updateNSView(_ webView: WKWebView, context: Context) {
    context.coordinator.update(patch: patch, theme: theme)
  }

  final class Coordinator: NSObject, WKNavigationDelegate {
    private var bridge: PierreDiffBridge?
    private var latestPatch: String?
    private var latestTheme: PierreDiffTheme?

    func attach(_ webView: WKWebView) {
      let bridge = PierreDiffBridge(webView: webView)
      self.bridge = bridge
      bridge.loadPanel()
    }

    func update(patch: String, theme: PierreDiffTheme) {
      guard let bridge else {
        return
      }
      if latestTheme != theme {
        latestTheme = theme
        bridge.setTheme(theme)
      }
      if latestPatch != patch {
        latestPatch = patch
        bridge.renderPatch(patch)
      }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      guard let bridge else {
        return
      }
      bridge.didFinishNavigation()
      if let latestTheme {
        bridge.setTheme(latestTheme)
      }
      if let latestPatch {
        bridge.renderPatch(latestPatch)
      } else {
        bridge.clear()
      }
    }
  }
}
