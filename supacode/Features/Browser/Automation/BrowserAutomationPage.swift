import Foundation

nonisolated struct BrowserPageSnapshot: Equatable, Sendable {
  var text: String
  var url: String
  var title: String

  var header: String {
    title.isEmpty ? "<\(url)>" : "\(title) <\(url)>"
  }
}

nonisolated struct BrowserPageDialog: Hashable, Sendable {
  enum Kind: String, Hashable, Sendable {
    case alert
    case confirm
    case prompt
  }

  var kind: Kind
  var message: String
  var defaultText: String?

  var summary: String {
    "\(kind.rawValue) \"\(message)\""
  }
}

nonisolated enum BrowserPageAction: Equatable, Sendable {
  case click(target: String)
  case fill(target: String, text: String)
  case select(target: String, option: String)
  case press(key: String, target: String?)
  case wait(BrowserPageWait, timeout: Duration)

  static let timeout = Duration.seconds(10)
}

nonisolated enum BrowserAutomationError: Error, Equatable, Sendable {
  case unavailable
  case contextLost
  case timedOut
  case dialogOpened(BrowserPageDialog)
  case rejected(String)
  case internalFailure(String)
}

protocol BrowserAutomationPage: AnyObject {
  var isLoadingPage: Bool { get }
  var documentGeneration: Int { get }
  var lastSnapshot: BrowserPageSnapshot? { get set }
  var pendingDialog: BrowserPageDialog? { get }

  func loadPage(_ url: URL)
  func waitUntilLoaded(timeout: Duration) async -> Bool
  func snapshot() async throws(BrowserAutomationError) -> BrowserPageSnapshot
  func perform(_ action: BrowserPageAction) async throws(BrowserAutomationError) -> String
  func settle() async
  func evaluate(_ source: String) async throws(BrowserAutomationError) -> String
  func saveScreenshot(to path: String?) async throws(BrowserAutomationError) -> String
  func consoleMessages(clearing: Bool) -> [String]
  func answerDialog(_ answer: BrowserDialogAnswer) -> BrowserPageDialog?
}
