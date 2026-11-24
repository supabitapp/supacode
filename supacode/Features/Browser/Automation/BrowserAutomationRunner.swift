import Foundation

struct BrowserAutomationRunner {
  static let snapshotByteLimit = 20_000
  static let navigationByteLimit = 4_000
  static let deltaLineLimit = 30
  static let loadTimeout = Duration.seconds(30)
  static let dialogHint = "Answer it with `dialog accept` or `dialog dismiss`."

  private struct ReportBase {
    var generation: Int
    var snapshot: BrowserPageSnapshot
  }

  private struct Progress {
    var result = BrowserAutomationResult()
    var reportBase: ReportBase?
    var isLastStep = false
  }

  let page: any BrowserAutomationPage
  var reportsChanges = true
  var isCallerGone: () -> Bool = { false }

  func run(_ steps: [BrowserAutomationStep]) async -> BrowserAutomationResult {
    if page.pendingDialog == nil, !page.isLoadingPage {
      await page.refreshSecrets()
    }
    return await runSteps(steps).mapPageText(page.redacted)
  }

  private func runSteps(_ steps: [BrowserAutomationStep]) async -> BrowserAutomationResult {
    var progress = Progress()
    for (index, step) in steps.enumerated() {
      progress.isLastStep = index == steps.count - 1
      let label = steps.count > 1 ? "step \(index + 1) (\(step.verb)): " : ""
      guard !isCallerGone() else {
        progress.result.failure = "Stopped before step \(index + 1): the caller disconnected."
        return progress.result
      }
      if let dialog = page.pendingDialog, !step.worksWhileADialogIsOpen {
        progress.result.failure = "\(label)A page dialog is open: \(dialog.summary). \(Self.dialogHint)"
        return progress.result
      }
      do {
        try await run(step, &progress)
      } catch .dialogOpened(let dialog) {
        progress.result.lines += Self.dialogLines(dialog)
        if !progress.isLastStep {
          progress.result.failure = "Stopped before step \(index + 2): a page dialog is open."
        }
        return progress.result
      } catch {
        progress.result.failure = label + Self.message(for: error, step: step)
        return progress.result
      }
    }
    guard let reportBase = progress.reportBase else { return progress.result }
    do {
      progress.result.lines += try await report(since: reportBase)
    } catch {
      progress.result.failure = "The action ran, but the page could not be read: \(Self.message(for: error, step: nil))"
    }
    return progress.result
  }

  private func run(_ step: BrowserAutomationStep, _ progress: inout Progress) async throws(BrowserAutomationError) {
    switch step {
    case .snapshot(let full, let scope):
      progress.result.lines += try await snapshotLines(full: full, scope: scope)
      progress.reportBase = nil
    case .screenshot(let path):
      progress.result.lines.append("saved \(try await page.saveScreenshot(to: path))")
    case .console(let clear):
      progress.result.lines.append(Self.consoleText(page.consoleMessages(clearing: clear)))
    case .evaluate(let source):
      let value = try await page.evaluate(source)
      progress.result.lines.append(
        BrowserSnapshotText.capped(value, maxBytes: Self.snapshotByteLimit, hint: "Return less from the script."))
      if !progress.isLastStep {
        await settle()
      }
    case .navigate(let url, let timeout):
      try await change(&progress) { () async throws(BrowserAutomationError) in
        page.loadPage(url)
        let finished = await page.waitUntilLoaded(timeout: timeout ?? Self.loadTimeout)
        return "opened \(url.absoluteString)" + (finished ? "" : " (still loading)")
      }
    case .click(let target):
      try await change(&progress) { () async throws(BrowserAutomationError) in
        try await page.perform(.click(target: target))
      }
    case .fill(let target, let text):
      try await change(&progress) { () async throws(BrowserAutomationError) in
        try await page.perform(.fill(target: target, text: text))
      }
    case .select(let target, let option):
      try await change(&progress) { () async throws(BrowserAutomationError) in
        try await page.perform(.select(target: target, option: option))
      }
    case .press(let key, let target):
      try await change(&progress) { () async throws(BrowserAutomationError) in
        try await page.perform(.press(key: key, target: target))
      }
    case .wait(let condition, let timeout):
      try await change(&progress) { () async throws(BrowserAutomationError) in
        try await wait(for: condition, timeout: timeout)
      }
    case .dialog(let answer):
      try await change(&progress) { () throws(BrowserAutomationError) in
        guard let dialog = page.answerDialog(answer) else {
          throw .rejected("No page dialog is open.")
        }
        return (answer == .dismiss ? "dismissed " : "accepted ") + dialog.summary
      }
    }
  }

  private func change(
    _ progress: inout Progress,
    _ act: () async throws(BrowserAutomationError) -> String
  ) async throws(BrowserAutomationError) {
    if progress.reportBase == nil, reportsChanges {
      progress.reportBase = try await captureBase()
    }
    progress.result.lines.append(try await act())
    if reportsChanges || !progress.isLastStep {
      await settle()
    }
  }

  private func snapshotLines(full: Bool, scope: String?) async throws(BrowserAutomationError) -> [String] {
    await waitForLoad()
    let snapshot = try await readPage()
    var text = snapshot.text
    if let scope {
      guard let scoped = BrowserSnapshotText.scoped(text, to: scope) else {
        throw .rejected("Ref \(scope) is not on the page now. Run `snapshot` for current refs.")
      }
      text = scoped
    }
    if !full {
      text = BrowserSnapshotText.interactive(text)
    }
    return ["page: \(snapshot.header)", Self.shown(text, maxBytes: Self.snapshotByteLimit)]
  }

  private func readPage() async throws(BrowserAutomationError) -> BrowserPageSnapshot {
    let snapshot = try await page.snapshot()
    page.lastSnapshot = snapshot
    return snapshot
  }

  private func captureBase() async throws(BrowserAutomationError) -> ReportBase? {
    guard page.pendingDialog == nil else {
      return page.lastSnapshot.map { ReportBase(generation: page.documentGeneration, snapshot: $0) }
    }
    await waitForLoad()
    if let known = page.lastSnapshot {
      return ReportBase(generation: page.documentGeneration, snapshot: known)
    }
    let snapshot = try await readPage()
    return ReportBase(generation: page.documentGeneration, snapshot: snapshot)
  }

  private func wait(for condition: BrowserPageWait, timeout: Duration) async throws(BrowserAutomationError) -> String {
    let started = ContinuousClock.now
    while true {
      let remaining = timeout - (ContinuousClock.now - started)
      do {
        return try await page.perform(.wait(condition, timeout: max(remaining, .milliseconds(1))))
      } catch .contextLost where remaining > .zero {
        _ = await page.waitUntilLoaded(timeout: remaining)
      }
    }
  }

  private func settle() async {
    await page.settle()
    await waitForLoad()
  }

  private func waitForLoad() async {
    guard page.isLoadingPage else { return }
    _ = await page.waitUntilLoaded(timeout: Self.loadTimeout)
  }

  private func report(since base: ReportBase) async throws(BrowserAutomationError) -> [String] {
    if let dialog = page.pendingDialog {
      return Self.dialogLines(dialog)
    }
    let snapshot = try await readPage()
    guard page.documentGeneration == base.generation else {
      return [
        "navigated: \(snapshot.header)",
        Self.shown(BrowserSnapshotText.interactive(snapshot.text), maxBytes: Self.navigationByteLimit),
      ]
    }
    var lines: [String] = []
    if snapshot.url != base.snapshot.url {
      lines.append("url: \(snapshot.url)")
    }
    lines.append(
      BrowserSnapshotDelta(from: base.snapshot.text, to: snapshot.text).rendered(maxLines: Self.deltaLineLimit))
    return lines
  }

  private static func dialogLines(_ dialog: BrowserPageDialog) -> [String] {
    ["a page dialog opened: \(dialog.summary)", dialogHint]
  }

  private static func consoleText(_ messages: [String]) -> String {
    guard !messages.isEmpty else { return "(no console messages)" }
    var kept: [String] = []
    var bytes = 0
    for message in messages.reversed() {
      bytes += message.utf8.count + 1
      guard bytes <= snapshotByteLimit else { break }
      kept.append(message)
    }
    let dropped = messages.count - kept.count
    let notice = dropped > 0 ? ["... \(dropped) earlier messages not shown."] : []
    return (notice + kept.reversed()).joined(separator: "\n")
  }

  private static func shown(_ text: String, maxBytes: Int) -> String {
    guard !text.isEmpty else { return "(no interactive elements. Use `snapshot --full` for the page content.)" }
    return BrowserSnapshotText.capped(
      text,
      maxBytes: maxBytes,
      hint: "Run `snapshot`, or `snapshot --scope <ref>` for one part of the page."
    )
  }

  private static func message(for error: BrowserAutomationError, step: BrowserAutomationStep?) -> String {
    switch error {
    case .rejected(let message), .internalFailure(let message):
      message
    case .unavailable:
      "The browser tab has no live page."
    case .contextLost:
      "The page navigated away before the command finished."
    case .dialogOpened(let dialog):
      "A page dialog is open: \(dialog.summary). \(dialogHint)"
    case .timedOut where step?.actsOnThePage == true:
      "Timed out. The action may have happened."
    case .timedOut:
      "Timed out."
    }
  }
}

extension BrowserAutomationStep {
  fileprivate var worksWhileADialogIsOpen: Bool {
    switch self {
    case .dialog, .screenshot, .console: true
    case .navigate, .snapshot, .click, .fill, .select, .press, .wait, .evaluate: false
    }
  }

  fileprivate var actsOnThePage: Bool {
    switch self {
    case .click, .fill, .select, .press, .evaluate: true
    case .navigate, .snapshot, .wait, .screenshot, .console, .dialog: false
    }
  }
}
