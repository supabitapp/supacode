import Foundation
import WebKit

final class BrowserConsoleCapture: NSObject, WKScriptMessageHandler {
  static let handlerName = "supacodeConsole"
  static let entryLimit = 200
  static let entryLengthLimit = 500

  private(set) var entries: [String] = []
  private weak var installedWebView: WKWebView?

  nonisolated deinit {}

  func install(in webView: WKWebView) {
    guard installedWebView !== webView, let hook = BrowserAutomationScripts.consoleHook else { return }
    installedWebView = webView
    let controller = webView.configuration.userContentController
    controller.add(self, contentWorld: .page, name: Self.handlerName)
    controller.addUserScript(
      WKUserScript(source: hook, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
    webView.evaluateJavaScript(hook, in: nil, in: .page)
  }

  func drain(clearing: Bool) -> [String] {
    defer {
      if clearing {
        entries = []
      }
    }
    return entries
  }

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    guard let body = message.body as? [String: Any], let text = body["text"] as? String else { return }
    let level = body["level"] as? String ?? "log"
    entries.append("\(level): \(text.prefix(Self.entryLengthLimit))".replacing("\n", with: "\n  "))
    entries.removeFirst(max(entries.count - Self.entryLimit, 0))
  }
}
