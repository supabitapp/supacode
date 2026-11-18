import Foundation

nonisolated struct BrowserSnapshotBaseline: Equatable, Sendable {
  var text: String
  var url: String
}

protocol BrowserAutomationPage: AnyObject {
  var isLoadingPage: Bool { get }
  var documentGeneration: Int { get }
  var snapshotBaseline: BrowserSnapshotBaseline? { get set }
  func loadPage(_ url: URL)
  func waitUntilLoaded(timeout: Duration) async -> Bool
  func drive(
    _ command: String,
    _ arguments: [String: Any],
    timeout: Duration
  ) async throws(BrowserAutomationError) -> BrowserDriverReply
}

struct BrowserAutomationRunner {
  static let snapshotByteLimit = 20_000
  static let navigationByteLimit = 4_000
  static let deltaLineLimit = 30
  static let actionTimeout = Duration.seconds(10)
  static let loadTimeout = Duration.seconds(30)
  static let defaultWaitSeconds = 10.0

  private struct ReportBase {
    var generation: Int
    var baseline: BrowserSnapshotBaseline
  }

  let page: any BrowserAutomationPage
  var reportsChanges = true

  func run(_ steps: [BrowserAutomationStep]) async -> BrowserAutomationResult {
    var result = BrowserAutomationResult()
    var reportBase: ReportBase?
    for (index, step) in steps.enumerated() {
      do {
        if step.verb == .snapshot {
          result.lines += try await snapshot(step)
          reportBase = nil
          continue
        }
        if reportBase == nil, reportsChanges {
          reportBase = try await captureBase()
        }
        result.lines.append(try await perform(step))
        if reportsChanges || index < steps.count - 1 {
          await settle()
        }
      } catch {
        let message = Self.message(for: error, verb: step.verb)
        result.failure = steps.count > 1 ? "step \(index + 1) (\(step.verb.rawValue)): \(message)" : message
        return result
      }
    }
    guard let reportBase else { return result }
    do {
      result.lines += try await report(since: reportBase)
    } catch {
      result.failure = "The action ran, but the page could not be read: \(Self.message(for: error, verb: .snapshot))"
    }
    return result
  }

  private func snapshot(_ step: BrowserAutomationStep) async throws(BrowserAutomationError) -> [String] {
    await waitForLoad()
    let reply = try await page.drive("snapshot", [:], timeout: Self.actionTimeout)
    let full = reply.text ?? ""
    page.snapshotBaseline = BrowserSnapshotBaseline(text: full, url: reply.url ?? "")
    var text = full
    if let scope = step.scope {
      guard let scoped = BrowserSnapshotText.scoped(full, to: scope) else {
        throw .rejected("Ref \(scope) is not on the page now. Run `snapshot` for current refs.")
      }
      text = scoped
    }
    if step.full != true {
      text = BrowserSnapshotText.interactive(text)
    }
    return ["page: \(Self.header(reply))", Self.shown(text, maxBytes: Self.snapshotByteLimit)]
  }

  private func captureBase() async throws(BrowserAutomationError) -> ReportBase {
    await waitForLoad()
    if let baseline = page.snapshotBaseline {
      return ReportBase(generation: page.documentGeneration, baseline: baseline)
    }
    let reply = try await page.drive("snapshot", [:], timeout: Self.actionTimeout)
    let baseline = BrowserSnapshotBaseline(text: reply.text ?? "", url: reply.url ?? "")
    page.snapshotBaseline = baseline
    return ReportBase(generation: page.documentGeneration, baseline: baseline)
  }

  private func perform(_ step: BrowserAutomationStep) async throws(BrowserAutomationError) -> String {
    switch step.verb {
    case .navigate:
      guard let url = step.url.flatMap(BrowserAddress.resolve) else {
        throw .rejected("navigate needs a URL.")
      }
      page.loadPage(url)
      let finished = await page.waitUntilLoaded(timeout: step.timeout.map { .seconds($0) } ?? Self.loadTimeout)
      return "opened \(url.absoluteString)" + (finished ? "" : " (still loading)")
    case .click:
      return try await act("click", ["target": try Self.required(step.target, "a target")])
    case .fill:
      return try await act(
        "fill",
        ["target": try Self.required(step.target, "a target"), "text": try Self.present(step.text, "text")]
      )
    case .select:
      return try await act(
        "select",
        ["target": try Self.required(step.target, "a target"), "option": try Self.present(step.option, "an option")]
      )
    case .press:
      var arguments: [String: Any] = ["key": try Self.required(step.key, "a key")]
      arguments["target"] = step.target
      return try await act("press", arguments)
    case .wait:
      return try await wait(step)
    case .snapshot:
      return ""
    }
  }

  private func act(_ command: String, _ arguments: [String: Any]) async throws(BrowserAutomationError) -> String {
    try await page.drive(command, arguments, timeout: Self.actionTimeout).ack ?? command
  }

  private func wait(_ step: BrowserAutomationStep) async throws(BrowserAutomationError) -> String {
    var arguments: [String: Any] = [:]
    arguments["text"] = step.text
    arguments["url"] = step.url
    arguments["target"] = step.target
    guard !arguments.isEmpty else {
      throw .rejected("wait needs --text, --url, or a target.")
    }
    if step.hidden == true {
      arguments["state"] = "hidden"
    }
    let total = Duration.seconds(step.timeout ?? Self.defaultWaitSeconds)
    let started = ContinuousClock.now
    while true {
      let remaining = total - (ContinuousClock.now - started)
      let budget = max(remaining, .milliseconds(1))
      arguments["timeoutMs"] = Double(budget.components.seconds) * 1000 + Double(budget.components.attoseconds) / 1e15
      do {
        return try await page.drive("wait", arguments, timeout: budget + .seconds(2)).ack ?? "wait finished"
      } catch .contextLost where remaining > .zero {
        _ = await page.waitUntilLoaded(timeout: remaining)
      }
    }
  }

  private func settle() async {
    _ = try? await page.drive("settle", [:], timeout: .seconds(3))
    await waitForLoad()
  }

  private func waitForLoad() async {
    guard page.isLoadingPage else { return }
    _ = await page.waitUntilLoaded(timeout: Self.loadTimeout)
  }

  private func report(since base: ReportBase) async throws(BrowserAutomationError) -> [String] {
    let reply = try await page.drive("snapshot", [:], timeout: Self.actionTimeout)
    let text = reply.text ?? ""
    page.snapshotBaseline = BrowserSnapshotBaseline(text: text, url: reply.url ?? "")
    guard page.documentGeneration == base.generation else {
      return [
        "navigated: \(Self.header(reply))",
        Self.shown(BrowserSnapshotText.interactive(text), maxBytes: Self.navigationByteLimit),
      ]
    }
    var lines: [String] = []
    if let url = reply.url, url != base.baseline.url {
      lines.append("url: \(url)")
    }
    lines.append(BrowserSnapshotDelta(from: base.baseline.text, to: text).rendered(maxLines: Self.deltaLineLimit))
    return lines
  }

  private static func header(_ reply: BrowserDriverReply) -> String {
    let url = "<\(reply.url ?? "")>"
    guard let title = reply.title, !title.isEmpty else { return url }
    return "\(title) \(url)"
  }

  private static func shown(_ text: String, maxBytes: Int) -> String {
    guard !text.isEmpty else { return "(no interactive elements. Use `snapshot --full` for the page content.)" }
    return BrowserSnapshotText.capped(
      text,
      maxBytes: maxBytes,
      hint: "Run `snapshot`, or `snapshot --scope <ref>` for one part of the page."
    )
  }

  private static func present(_ value: String?, _ name: String) throws(BrowserAutomationError) -> String {
    guard let value else { throw .rejected("Missing \(name).") }
    return value
  }

  private static func required(_ value: String?, _ name: String) throws(BrowserAutomationError) -> String {
    let value = try present(value, name)
    guard !value.isEmpty else { throw .rejected("Missing \(name).") }
    return value
  }

  private static func message(for error: BrowserAutomationError, verb: BrowserAutomationStep.Verb) -> String {
    switch error {
    case .rejected(let message), .internalFailure(let message):
      message
    case .unavailable:
      "The browser tab has no live page."
    case .contextLost:
      "The page navigated away before the command finished."
    case .timedOut where [.click, .fill, .select, .press].contains(verb):
      "Timed out. The action may have happened. A page dialog may be blocking the page."
    case .timedOut:
      "Timed out."
    }
  }
}
