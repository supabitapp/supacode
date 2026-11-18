import Foundation

nonisolated enum BrowserPageWait: Equatable, Sendable {
  case text(String)
  case url(String)
  case target(String, hidden: Bool)
}

nonisolated enum BrowserDialogAnswer: Equatable, Sendable {
  case accept(text: String?)
  case dismiss
}

nonisolated enum BrowserAutomationStep: Equatable, Sendable {
  case navigate(url: URL, timeout: Duration?)
  case snapshot(full: Bool, scope: String?)
  case click(target: String)
  case fill(target: String, text: String)
  case select(target: String, option: String)
  case press(key: String, target: String?)
  case wait(BrowserPageWait, timeout: Duration)
  case evaluate(source: String)
  case screenshot(path: String?)
  case console(clear: Bool)
  case dialog(BrowserDialogAnswer)

  static let maximumTimeoutSeconds = 600.0
  static let defaultWaitTimeout = Duration.seconds(10)

  var verb: String {
    switch self {
    case .navigate: "navigate"
    case .snapshot: "snapshot"
    case .click: "click"
    case .fill: "fill"
    case .select: "select"
    case .press: "press"
    case .wait: "wait"
    case .evaluate: "eval"
    case .screenshot: "screenshot"
    case .console: "console"
    case .dialog: "dialog"
    }
  }
}

nonisolated struct BrowserAutomationRequestError: Error, Equatable, Sendable {
  var message: String
}

nonisolated struct BrowserAutomationRequest: Equatable, Sendable {
  enum Operation: Equatable, Sendable {
    case open(url: URL?, background: Bool)
    case run(steps: [BrowserAutomationStep], quiet: Bool)
    case listTabs
    case close
  }

  var tabID: String?
  var operation: Operation

  init(tabID: String? = nil, operation: Operation) {
    self.tabID = tabID
    self.operation = operation
  }

  init(json: String) throws(BrowserAutomationRequestError) {
    guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(json.utf8)) else {
      throw BrowserAutomationRequestError(message: "Malformed browser request.")
    }
    tabID = payload.tabID
    switch payload.operation {
    case "open":
      operation = .open(url: payload.url.flatMap(BrowserAddress.resolve), background: payload.background ?? false)
    case "run":
      var steps: [BrowserAutomationStep] = []
      for (index, step) in (payload.steps ?? []).enumerated() {
        do {
          steps.append(try BrowserAutomationStep(step))
        } catch {
          throw BrowserAutomationRequestError(message: "Step \(index + 1): \(error.message)")
        }
      }
      operation = .run(steps: steps, quiet: payload.quiet ?? false)
    case "tabs":
      operation = .listTabs
    case "close":
      operation = .close
    default:
      throw BrowserAutomationRequestError(message: "Unknown browser operation `\(payload.operation)`.")
    }
  }

  private struct Payload: Decodable {
    var tabID: String?
    var operation: String
    var url: String?
    var background: Bool?
    var steps: [BrowserAutomationStep.Payload]?
    var quiet: Bool?
  }
}

nonisolated extension BrowserAutomationStep {
  struct Payload: Decodable {
    var verb: String
    var target: String?
    var text: String?
    var url: String?
    var key: String?
    var option: String?
    var source: String?
    var path: String?
    var scope: String?
    var full: Bool?
    var hidden: Bool?
    var clear: Bool?
    var accept: Bool?
    var timeout: Double?
  }

  init(_ payload: Payload) throws(BrowserAutomationRequestError) {
    let timeout = payload.timeout.map { Duration.seconds(min(max($0, 0), Self.maximumTimeoutSeconds)) }
    switch payload.verb {
    case "navigate":
      let url = try Self.present(payload.url.flatMap(BrowserAddress.resolve), "navigate needs a URL.")
      self = .navigate(url: url, timeout: timeout)
    case "snapshot":
      self = .snapshot(full: payload.full ?? false, scope: payload.scope)
    case "click":
      self = .click(target: try Self.nonEmpty(payload.target, "click needs a target."))
    case "fill":
      self = .fill(
        target: try Self.nonEmpty(payload.target, "fill needs a target."),
        text: try Self.present(payload.text, "fill needs text.")
      )
    case "select":
      self = .select(
        target: try Self.nonEmpty(payload.target, "select needs a target."),
        option: try Self.present(payload.option, "select needs an option.")
      )
    case "press":
      self = .press(key: try Self.nonEmpty(payload.key, "press needs a key."), target: payload.target)
    case "wait":
      self = .wait(try Self.waitCondition(payload), timeout: timeout ?? Self.defaultWaitTimeout)
    case "eval":
      self = .evaluate(source: try Self.nonEmpty(payload.source, "eval needs an expression."))
    case "screenshot":
      self = .screenshot(path: payload.path)
    case "console":
      self = .console(clear: payload.clear ?? false)
    case "dialog":
      let accepts = try Self.present(payload.accept, "dialog needs accept or dismiss.")
      self = .dialog(accepts ? .accept(text: payload.text) : .dismiss)
    default:
      throw BrowserAutomationRequestError(message: "Unknown verb `\(payload.verb)`.")
    }
  }

  private static func waitCondition(_ payload: Payload) throws(BrowserAutomationRequestError) -> BrowserPageWait {
    if let text = payload.text {
      return .text(text)
    }
    if let url = payload.url {
      return .url(url)
    }
    if let target = payload.target, !target.isEmpty {
      return .target(target, hidden: payload.hidden ?? false)
    }
    throw BrowserAutomationRequestError(message: "wait needs text, a URL, or a target.")
  }

  private static func present<Value>(
    _ value: Value?,
    _ message: String
  ) throws(BrowserAutomationRequestError) -> Value {
    guard let value else {
      throw BrowserAutomationRequestError(message: message)
    }
    return value
  }

  private static func nonEmpty(_ value: String?, _ message: String) throws(BrowserAutomationRequestError) -> String {
    let value = try present(value, message)
    guard !value.isEmpty else {
      throw BrowserAutomationRequestError(message: message)
    }
    return value
  }
}

nonisolated struct BrowserAutomationResult: Equatable, Sendable {
  var lines: [String] = []
  var failure: String?
  var refusal: String?
  var createdTabID: String?

  func response(nonce: String) -> [String: String] {
    var fields: [String: String] = [:]
    fields["id"] = createdTabID
    var body = lines
    if let failure {
      body.append("failed: \(failure)")
      fields["error"] = "The browser command failed. The reason is in the page output."
    }
    if !body.isEmpty {
      fields["output"] = (["--- page \(nonce) ---"] + body + ["--- end \(nonce) ---"]).joined(separator: "\n")
    }
    if let refusal {
      fields["error"] = refusal
    }
    return fields
  }
}
