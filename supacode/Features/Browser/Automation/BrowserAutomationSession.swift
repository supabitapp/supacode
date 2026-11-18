import Foundation
import SupacodeSettingsShared
import WebKit

nonisolated enum BrowserAutomationScripts {
  static let engine = load("playwright-injected")
  static let driver = load("driver")
  static let consoleHook = load("console-hook")

  private static func load(_ name: String) -> String? {
    guard let url = Bundle.main.url(forResource: name, withExtension: "js", subdirectory: "BrowserAutomation") else {
      return nil
    }
    return try? String(contentsOf: url, encoding: .utf8)
  }
}

final class BrowserAutomationSession {
  private nonisolated struct Reply: Sendable {
    var needsBootstrap = false
    var succeeded = false
    var error: String?
    var ack: String?
    var text: String?
    var url: String?
    var title: String?
    var secrets: [String] = []
  }

  private struct Script {
    var body: String
    var arguments: [String: Any] = [:]
    var world: WKContentWorld
  }

  private struct PendingCall {
    var continuation: CheckedContinuation<Result<Reply, BrowserAutomationError>, Never>
    var timeout: Task<Void, Never>
  }

  private static let logger = SupaLogger("BrowserAutomation")
  private static let rememberedSecretLimit = 32
  private static let settleTimeout = Duration.seconds(3)
  private static let driverBody = """
    const driver = globalThis.__supacodeDriver;
    if (!driver) return { needsBootstrap: true };
    return await driver.run(command, args);
    """
  private static let engineOptions: [String: Any] = [
    "isUnderTest": false,
    "sdkLanguage": "javascript",
    "testIdAttributeName": "data-testid",
    "stableRafCount": 1,
    "browserName": "webkit",
    "shouldPrependErrorPrefix": false,
    "isUtilityWorld": true,
    "customEngines": [Any](),
  ]

  let console = BrowserConsoleCapture()
  private let world = WKContentWorld.world(name: "supacode-automation")
  private let clock: any Clock<Duration>
  private var pending: [UUID: PendingCall] = [:]
  private var queueTail: Task<Void, Never>?
  private var lastActivity: ContinuousClock.Instant?
  private var requestsInFlight = 0
  private var secrets: [String] = []
  private(set) var generation = 0
  var lastSnapshot: BrowserPageSnapshot?

  init(clock: any Clock<Duration> = ContinuousClock()) {
    self.clock = clock
  }

  nonisolated deinit {}

  func wasActive(within window: Duration) -> Bool {
    requestsInFlight > 0 || lastActivity.map { ContinuousClock.now - $0 < window } ?? false
  }

  func documentChanged() {
    lastSnapshot = nil
    abandonPendingCalls(.contextLost)
  }

  func dialogOpened(_ dialog: BrowserPageDialog) {
    abandonPendingCalls(.dialogOpened(dialog))
  }

  func serialized<Value: Sendable>(_ work: @escaping @MainActor () async -> Value) async -> Value {
    let previous = queueTail
    requestsInFlight += 1
    let task = Task {
      await previous?.value
      defer {
        requestsInFlight -= 1
        lastActivity = .now
      }
      return await work()
    }
    queueTail = Task { _ = await task.value }
    return await task.value
  }

  func snapshot(in webView: WKWebView) async throws(BrowserAutomationError) -> BrowserPageSnapshot {
    let reply = try await drive("snapshot", [:], in: webView, timeout: BrowserPageAction.timeout)
    return BrowserPageSnapshot(text: reply.text ?? "", url: reply.url ?? "", title: reply.title ?? "")
  }

  func perform(_ action: BrowserPageAction, in webView: WKWebView) async throws(BrowserAutomationError) -> String {
    try await drive(action.name, action.arguments, in: webView, timeout: action.callTimeout).ack ?? action.name
  }

  func settle(in webView: WKWebView) async {
    _ = try? await drive("settle", [:], in: webView, timeout: Self.settleTimeout)
  }

  func evaluate(_ source: String, in webView: WKWebView) async throws(BrowserAutomationError) -> String {
    let asExpression = "return (\(source)\n);"
    let asStatements = "\(source)\n"
    do {
      return try await evaluate(body: asExpression, in: webView)
    } catch .internalFailure {
      do {
        return try await evaluate(body: asStatements, in: webView)
      } catch .internalFailure(let message) {
        throw .rejected("The script failed: \(message)")
      }
    }
  }

  func redacted(_ text: String) -> String {
    secrets.reduce(text) { $0.replacing($1, with: "[masked]") }
  }

  func waitUntilLoaded(_ webView: WKWebView, timeout: Duration) async -> Bool {
    let pollInterval = Duration.milliseconds(50)
    var waited = Duration.zero
    while webView.isLoading {
      guard waited < timeout, (try? await clock.sleep(for: pollInterval)) != nil else { return false }
      waited += pollInterval
    }
    return true
  }

  private func evaluate(body: String, in webView: WKWebView) async throws(BrowserAutomationError) -> String {
    let script = """
      let value;
      try {
        value = await (async () => { \(body) })();
      } catch (error) {
        return { thrown: String(error) };
      }
      if (value === undefined) return { value: "undefined" };
      try {
        const json = JSON.stringify(value, null, 2);
        return { value: json === undefined ? String(value) : json };
      } catch (error) {
        return { value: String(value) };
      }
      """
    let page = Script(body: script, world: .page)
    let reply = try await call(page, in: webView, timeout: BrowserPageAction.timeout) { result in
      switch result {
      case .success(let outcome):
        let fields = outcome as? [String: Any]
        return .success(
          Reply(
            succeeded: fields?["thrown"] == nil, error: fields?["thrown"] as? String, text: fields?["value"] as? String)
        )
      case .failure(let error):
        return .failure(.internalFailure(Self.scriptErrorMessage(error)))
      }
    }
    guard reply.succeeded else {
      throw .rejected("The script failed: \(reply.error ?? "")")
    }
    return reply.text ?? ""
  }

  private func drive(
    _ command: String,
    _ arguments: [String: Any],
    in webView: WKWebView,
    timeout: Duration
  ) async throws(BrowserAutomationError) -> Reply {
    let callArguments: [String: Any] = ["command": command, "args": arguments]
    var reply = try await callDriver(callArguments, in: webView, timeout: timeout)
    if reply.needsBootstrap {
      try await bootstrap(in: webView)
      reply = try await callDriver(callArguments, in: webView, timeout: timeout)
    }
    remember(reply.secrets)
    guard reply.succeeded else {
      throw .rejected(reply.error ?? "The browser command failed.")
    }
    return reply
  }

  private func callDriver(
    _ arguments: [String: Any],
    in webView: WKWebView,
    timeout: Duration
  ) async throws(BrowserAutomationError) -> Reply {
    let script = Script(body: Self.driverBody, arguments: arguments, world: world)
    return try await call(script, in: webView, timeout: timeout, parse: Self.driverReply)
  }

  private func bootstrap(in webView: WKWebView) async throws(BrowserAutomationError) {
    guard let engine = BrowserAutomationScripts.engine, let driver = BrowserAutomationScripts.driver else {
      throw .internalFailure("The browser automation scripts are missing from the app bundle.")
    }
    generation += 1
    lastSnapshot = nil
    let body = """
      if (globalThis.__supacodeDriver) return { ok: true };
      const module = {};
      \(engine)
      const engine = new (module.exports.InjectedScript())(globalThis, options);
      \(driver)
      globalThis.__supacodeDriver = supacodeCreateDriver(engine, { refPrefix });
      return { ok: true };
      """
    let arguments: [String: Any] = [
      "options": Self.engineOptions,
      "refPrefix": generation == 1 ? "" : "p\(generation)",
    ]
    let script = Script(body: body, arguments: arguments, world: world)
    let reply = try await call(script, in: webView, timeout: BrowserPageAction.timeout, parse: Self.driverReply)
    guard reply.succeeded else {
      throw .internalFailure(reply.error ?? "The browser automation scripts failed to start.")
    }
  }

  private func call(
    _ script: Script,
    in webView: WKWebView,
    timeout: Duration,
    parse: @escaping (Result<Any, any Error>) -> Result<Reply, BrowserAutomationError>
  ) async throws(BrowserAutomationError) -> Reply {
    let id = UUID()
    let result = await withCheckedContinuation { continuation in
      let timeoutTask = Task { [weak self, clock] in
        guard (try? await clock.sleep(for: timeout)) != nil else { return }
        self?.finish(id, .failure(.timedOut))
      }
      pending[id] = PendingCall(continuation: continuation, timeout: timeoutTask)
      webView.callAsyncJavaScript(
        script.body, arguments: script.arguments, in: nil, in: script.world
      ) { [weak self, weak webView] result in
        guard let self, pending[id] != nil else { return }
        if case .failure = result, webView?.isLoading == true {
          finish(id, .failure(.contextLost))
        } else {
          finish(id, parse(result))
        }
      }
    }
    return try result.get()
  }

  private func finish(_ id: UUID, _ result: Result<Reply, BrowserAutomationError>) {
    guard let call = pending.removeValue(forKey: id) else { return }
    call.timeout.cancel()
    call.continuation.resume(returning: result)
  }

  private func abandonPendingCalls(_ error: BrowserAutomationError) {
    for id in Array(pending.keys) {
      finish(id, .failure(error))
    }
  }

  private func remember(_ values: [String]) {
    let known = Set(secrets)
    secrets.append(contentsOf: values.filter { !known.contains($0) })
    secrets.sort { $0.count > $1.count }
    secrets.removeLast(max(secrets.count - Self.rememberedSecretLimit, 0))
  }

  private static func scriptErrorMessage(_ error: any Error) -> String {
    (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
  }

  private static func driverReply(_ result: Result<Any, any Error>) -> Result<Reply, BrowserAutomationError> {
    switch result {
    case .failure(let error):
      logger.warning("Browser automation script call failed: \(scriptErrorMessage(error))")
      return .failure(.internalFailure("The page rejected the automation script: \(scriptErrorMessage(error))"))
    case .success(let value):
      guard let fields = value as? [String: Any] else {
        return .failure(.internalFailure("The page returned an unexpected automation result."))
      }
      return .success(
        Reply(
          needsBootstrap: fields["needsBootstrap"] as? Bool ?? false,
          succeeded: fields["ok"] as? Bool ?? false,
          error: fields["error"] as? String,
          ack: fields["ack"] as? String,
          text: fields["text"] as? String,
          url: fields["url"] as? String,
          title: fields["title"] as? String,
          secrets: fields["secrets"] as? [String] ?? []
        ))
    }
  }
}

extension BrowserPageAction {
  fileprivate var name: String {
    switch self {
    case .click: "click"
    case .fill: "fill"
    case .select: "select"
    case .press: "press"
    case .wait: "wait"
    }
  }

  fileprivate var callTimeout: Duration {
    if case .wait(_, let timeout) = self {
      return timeout + .seconds(2)
    }
    return Self.timeout
  }

  fileprivate var arguments: [String: Any] {
    switch self {
    case .click(let target):
      return ["target": target]
    case .fill(let target, let text):
      return ["target": target, "text": text]
    case .select(let target, let option):
      return ["target": target, "option": option]
    case .press(let key, let target):
      var arguments: [String: Any] = ["key": key]
      arguments["target"] = target
      return arguments
    case .wait(let condition, let timeout):
      let milliseconds =
        Double(timeout.components.seconds) * 1000 + Double(timeout.components.attoseconds) / 1e15
      var arguments: [String: Any] = ["timeoutMs": milliseconds]
      switch condition {
      case .text(let text):
        arguments["text"] = text
      case .url(let url):
        arguments["url"] = url
      case .target(let target, let hidden):
        arguments["target"] = target
        arguments["state"] = hidden ? "hidden" : "visible"
      }
      return arguments
    }
  }
}
