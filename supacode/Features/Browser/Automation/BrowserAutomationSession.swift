import Foundation
import SupacodeSettingsShared
import WebKit

nonisolated struct BrowserDriverReply: Equatable, Sendable {
  var ack: String?
  var text: String?
  var url: String?
  var title: String?
}

nonisolated enum BrowserAutomationError: Error, Equatable, Sendable {
  case unavailable
  case contextLost
  case timedOut
  case rejected(String)
  case internalFailure(String)
}

nonisolated enum BrowserAutomationScripts {
  static let engine = load("playwright-injected")
  static let driver = load("driver")

  private static func load(_ name: String) -> String? {
    guard let url = Bundle.main.url(forResource: name, withExtension: "js", subdirectory: "BrowserAutomation") else {
      return nil
    }
    return try? String(contentsOf: url, encoding: .utf8)
  }
}

final class BrowserAutomationSession {
  private nonisolated struct RawReply: Sendable {
    var needsBootstrap = false
    var succeeded = false
    var error: String?
    var reply = BrowserDriverReply()
    var secrets: [String] = []
  }

  private struct PendingCall {
    var continuation: CheckedContinuation<Result<RawReply, BrowserAutomationError>, Never>
    var timeout: Task<Void, Never>
  }

  private static let logger = SupaLogger("BrowserAutomation")
  private static let rememberedSecretLimit = 32
  private static let runBody = """
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

  private let world = WKContentWorld.world(name: "supacode-automation")
  private let clock: any Clock<Duration>
  private var pending: [UUID: PendingCall] = [:]
  private var queueTail: Task<Void, Never>?
  private var lastActivity: ContinuousClock.Instant?
  private var requestsInFlight = 0
  private var secrets: [String] = []
  private(set) var generation = 0
  var baseline: BrowserSnapshotBaseline?

  init(clock: any Clock<Duration> = ContinuousClock()) {
    self.clock = clock
  }

  nonisolated deinit {}

  func wasActive(within window: Duration) -> Bool {
    requestsInFlight > 0 || lastActivity.map { ContinuousClock.now - $0 < window } ?? false
  }

  func documentChanged() {
    for id in Array(pending.keys) {
      finish(id, .failure(.contextLost))
    }
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

  func run(
    _ command: String,
    _ arguments: [String: Any] = [:],
    in webView: WKWebView,
    timeout: Duration
  ) async throws(BrowserAutomationError) -> BrowserDriverReply {
    let callArguments: [String: Any] = ["command": command, "args": arguments]
    var raw = try await call(Self.runBody, callArguments, in: webView, timeout: timeout)
    if raw.needsBootstrap {
      try await bootstrap(in: webView)
      raw = try await call(Self.runBody, callArguments, in: webView, timeout: timeout)
    }
    remember(raw.secrets)
    guard raw.succeeded else {
      throw .rejected(redacted(raw.error ?? "The browser command failed."))
    }
    return BrowserDriverReply(
      ack: raw.reply.ack.map(redacted),
      text: raw.reply.text.map(redacted),
      url: raw.reply.url.map(redacted),
      title: raw.reply.title.map(redacted)
    )
  }

  func redacted(_ text: String) -> String {
    secrets.reduce(text) { $0.replacing($1, with: "[masked]") }
  }

  private func remember(_ values: [String]) {
    let known = Set(secrets)
    secrets.append(contentsOf: values.filter { !known.contains($0) })
    secrets.sort { $0.count > $1.count }
    secrets.removeLast(max(secrets.count - Self.rememberedSecretLimit, 0))
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

  private func bootstrap(in webView: WKWebView) async throws(BrowserAutomationError) {
    guard let engine = BrowserAutomationScripts.engine, let driver = BrowserAutomationScripts.driver else {
      throw .internalFailure("The browser automation scripts are missing from the app bundle.")
    }
    generation += 1
    baseline = nil
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
    let raw = try await call(body, arguments, in: webView, timeout: .seconds(10))
    guard raw.succeeded else {
      throw .internalFailure(raw.error ?? "The browser automation scripts failed to start.")
    }
  }

  private func call(
    _ body: String,
    _ arguments: [String: Any],
    in webView: WKWebView,
    timeout: Duration
  ) async throws(BrowserAutomationError) -> RawReply {
    let id = UUID()
    let result = await withCheckedContinuation { continuation in
      let timeoutTask = Task { [weak self, clock] in
        guard (try? await clock.sleep(for: timeout)) != nil else { return }
        self?.finish(id, .failure(.timedOut))
      }
      pending[id] = PendingCall(continuation: continuation, timeout: timeoutTask)
      webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: world) { [weak self, weak webView] result in
        guard let self, pending[id] != nil else { return }
        if case .failure = result, webView?.isLoading == true {
          finish(id, .failure(.contextLost))
        } else {
          finish(id, Self.parse(result))
        }
      }
    }
    return try result.get()
  }

  private func finish(_ id: UUID, _ result: Result<RawReply, BrowserAutomationError>) {
    guard let call = pending.removeValue(forKey: id) else { return }
    call.timeout.cancel()
    call.continuation.resume(returning: result)
  }

  private static func parse(_ result: Result<Any, any Error>) -> Result<RawReply, BrowserAutomationError> {
    switch result {
    case .failure(let error):
      logger.warning("Browser automation script call failed: \(error.localizedDescription)")
      return .failure(.internalFailure("The page rejected the automation script: \(error.localizedDescription)"))
    case .success(let value):
      guard let fields = value as? [String: Any] else {
        return .failure(.internalFailure("The page returned an unexpected automation result."))
      }
      return .success(
        RawReply(
          needsBootstrap: fields["needsBootstrap"] as? Bool ?? false,
          succeeded: fields["ok"] as? Bool ?? false,
          error: fields["error"] as? String,
          reply: BrowserDriverReply(
            ack: fields["ack"] as? String,
            text: fields["text"] as? String,
            url: fields["url"] as? String,
            title: fields["title"] as? String
          ),
          secrets: fields["secrets"] as? [String] ?? []
        ))
    }
  }
}
