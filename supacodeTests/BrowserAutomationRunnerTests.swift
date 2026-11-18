import Foundation
import Testing

@testable import supacode

@MainActor
struct BrowserAutomationRunnerTests {
  private final class FakePage: BrowserAutomationPage {
    enum Call: Equatable {
      case snapshot
      case perform(BrowserPageAction)
      case settle
      case evaluate(String)
      case screenshot(String?)
      case answer(BrowserDialogAnswer)
    }

    var isLoadingPage = false
    var documentGeneration = 1
    var lastSnapshot: BrowserPageSnapshot?
    var pendingDialog: BrowserPageDialog?
    var calls: [Call] = []
    var loadedURLs: [URL] = []
    var snapshots: [String]
    var url = "http://localhost/form"
    var title = "Form"
    var console: [String] = []
    var onPerform: (BrowserPageAction) throws(BrowserAutomationError) -> String? = { _ in nil }
    var onSettle: () -> Void = {}

    init(snapshots: [String]) {
      self.snapshots = snapshots
    }

    nonisolated deinit {}

    func loadPage(_ url: URL) {
      loadedURLs.append(url)
    }

    func waitUntilLoaded(timeout: Duration) async -> Bool {
      await Task.yield()
      isLoadingPage = false
      return true
    }

    func snapshot() async throws(BrowserAutomationError) -> BrowserPageSnapshot {
      await Task.yield()
      calls.append(.snapshot)
      let text = snapshots.count > 1 ? snapshots.removeFirst() : snapshots[0]
      return BrowserPageSnapshot(text: text, url: url, title: title)
    }

    func perform(_ action: BrowserPageAction) async throws(BrowserAutomationError) -> String {
      await Task.yield()
      calls.append(.perform(action))
      return try onPerform(action) ?? "done"
    }

    func settle() async {
      await Task.yield()
      calls.append(.settle)
      onSettle()
    }

    func evaluate(_ source: String) async throws(BrowserAutomationError) -> String {
      await Task.yield()
      calls.append(.evaluate(source))
      return "\"\(source)\""
    }

    func saveScreenshot(to path: String?) async throws(BrowserAutomationError) -> String {
      await Task.yield()
      calls.append(.screenshot(path))
      return path ?? "/tmp/shot.png"
    }

    func consoleMessages(clearing: Bool) -> [String] {
      defer {
        if clearing {
          console = []
        }
      }
      return console
    }

    func answerDialog(_ answer: BrowserDialogAnswer) -> BrowserPageDialog? {
      calls.append(.answer(answer))
      defer { pendingDialog = nil }
      return pendingDialog
    }

    func redacted(_ text: String) -> String {
      text.replacing("hunter2", with: "[masked]")
    }
  }

  private static let before = """
    - button "Save" [ref=e1]
    - status [ref=e2]: idle
    """
  private static let after = """
    - button "Save" [ref=e1]
    - status [ref=e2]: saved
    """
  private static let click = BrowserAutomationStep.click(target: "e1")
  private static let clicked = FakePage.Call.perform(.click(target: "e1"))
  private static let confirm = BrowserPageDialog(kind: .confirm, message: "Delete it?")

  @Test func anActionPrintsItsAcknowledgementAndWhatChanged() async {
    let page = FakePage(snapshots: [Self.before, Self.after])
    let result = await BrowserAutomationRunner(page: page).run([Self.click])
    #expect(page.calls == [.snapshot, Self.clicked, .settle, .snapshot])
    #expect(result == BrowserAutomationResult(lines: ["done", "changed:\n- status [ref=e2]: saved"]))
    #expect(page.lastSnapshot == BrowserPageSnapshot(text: Self.after, url: page.url, title: page.title))
  }

  @Test func aQuietActionDoesNotReadThePage() async {
    let page = FakePage(snapshots: [Self.before])
    let result = await BrowserAutomationRunner(page: page, reportsChanges: false).run([Self.click])
    #expect(page.calls == [Self.clicked])
    #expect(result.lines == ["done"])
  }

  @Test func anUnchangedPageSaysSo() async {
    let page = FakePage(snapshots: [Self.before])
    let result = await BrowserAutomationRunner(page: page).run([Self.click])
    #expect(result.lines == ["done", "no visible change"])
  }

  @Test func aPageThatWasAlreadyReadIsNotReadAgain() async {
    let page = FakePage(snapshots: [Self.after])
    page.lastSnapshot = BrowserPageSnapshot(text: Self.before, url: page.url, title: page.title)
    let result = await BrowserAutomationRunner(page: page).run([Self.click])
    #expect(page.calls == [Self.clicked, .settle, .snapshot])
    #expect(result.lines == ["done", "changed:\n- status [ref=e2]: saved"])
  }

  @Test func aBatchSettlesBetweenStepsAndReportsOnce() async {
    let page = FakePage(snapshots: [Self.before, Self.after])
    let fill = BrowserAutomationStep.fill(target: "e1", text: "")
    let result = await BrowserAutomationRunner(page: page).run([fill, Self.click])
    #expect(
      page.calls == [.snapshot, .perform(.fill(target: "e1", text: "")), .settle, Self.clicked, .settle, .snapshot])
    #expect(result.lines == ["done", "done", "changed:\n- status [ref=e2]: saved"])
  }

  @Test func aQuietBatchSettlesOnlyBetweenSteps() async {
    let page = FakePage(snapshots: [Self.before])
    let result = await BrowserAutomationRunner(page: page, reportsChanges: false).run([Self.click, Self.click])
    #expect(page.calls == [Self.clicked, .settle, Self.clicked])
    #expect(result.lines == ["done", "done"])
  }

  @Test func aNavigationPrintsTheNewPage() async {
    let page = FakePage(snapshots: [Self.before, "- heading \"Done\" [ref=p2e1]\n- link \"Home\" [ref=p2e2]"])
    page.onSettle = {
      page.documentGeneration = 2
      page.url = "http://localhost/done"
      page.title = "Done"
    }
    let result = await BrowserAutomationRunner(page: page).run([Self.click])
    #expect(result.lines == ["done", "navigated: Done <http://localhost/done>", "- link \"Home\" [ref=p2e2]"])
  }

  @Test func aNewURLInTheSameDocumentIsReported() async {
    let page = FakePage(snapshots: [Self.before, Self.after])
    page.onSettle = { page.url = "http://localhost/form#saved" }
    let result = await BrowserAutomationRunner(page: page).run([Self.click])
    #expect(result.lines == ["done", "url: http://localhost/form#saved", "changed:\n- status [ref=e2]: saved"])
  }

  @Test func aFailingStepStopsTheBatchAndIsNamed() async {
    let page = FakePage(snapshots: [Self.before])
    page.onPerform = { (action) throws(BrowserAutomationError) -> String? in
      if case .click = action {
        throw .rejected("button \"Save\" is disabled.")
      }
      return nil
    }
    let fill = BrowserAutomationStep.fill(target: "e1", text: "ada")
    let result = await BrowserAutomationRunner(page: page).run([fill, Self.click, .press(key: "Enter", target: nil)])
    #expect(page.calls == [.snapshot, .perform(.fill(target: "e1", text: "ada")), .settle, Self.clicked])
    #expect(result.lines == ["done"])
    #expect(result.failure == "step 2 (click): button \"Save\" is disabled.")
  }

  @Test func aTimedOutActionSaysItMayHaveHappened() async {
    let page = FakePage(snapshots: [Self.before])
    page.onPerform = { (_) throws(BrowserAutomationError) -> String? in throw .timedOut }
    let result = await BrowserAutomationRunner(page: page, reportsChanges: false).run([Self.click])
    #expect(result.failure == "Timed out. The action may have happened.")
  }

  @Test func aWaitStartsOverWhenTheDocumentChanges() async {
    let page = FakePage(snapshots: [Self.before])
    var attempts = 0
    page.onPerform = { (action) throws(BrowserAutomationError) -> String? in
      guard case .wait(.text("Welcome"), _) = action else { return nil }
      attempts += 1
      if attempts == 1 {
        throw .contextLost
      }
      return "found text \"Welcome\""
    }
    let wait = BrowserAutomationStep.wait(.text("Welcome"), timeout: .seconds(5))
    let result = await BrowserAutomationRunner(page: page, reportsChanges: false).run([wait])
    #expect(attempts == 2)
    #expect(result.lines == ["found text \"Welcome\""])
  }

  @Test func aBatchStopsWhenItsCallerHasGone() async {
    let page = FakePage(snapshots: [Self.before])
    var callerIsGone = false
    page.onPerform = { _ in
      callerIsGone = true
      return nil
    }
    let runner = BrowserAutomationRunner(page: page, reportsChanges: false, isCallerGone: { callerIsGone })
    let result = await runner.run([Self.click, Self.click, Self.click])
    #expect(page.calls == [Self.clicked, .settle])
    #expect(result.lines == ["done"])
    #expect(result.failure == "Stopped before step 2: the caller disconnected.")
  }

  @Test func navigateLoadsTheAddress() async throws {
    let page = FakePage(snapshots: [Self.before])
    let url = try #require(URL(string: "http://localhost:3000/login"))
    let result = await BrowserAutomationRunner(page: page, reportsChanges: false).run([
      .navigate(url: url, timeout: nil)
    ])
    #expect(page.loadedURLs == [url])
    #expect(result.lines == ["opened http://localhost:3000/login"])
  }

  @Test func snapshotPrintsInteractiveElementsUnderAPageLine() async {
    let page = FakePage(snapshots: ["- generic [ref=e1]:\n  - heading \"Title\" [ref=e2]\n  - button \"Save\" [ref=e3]"]
    )
    let result = await BrowserAutomationRunner(page: page).run([.snapshot(full: false, scope: nil)])
    #expect(result.lines == ["page: Form <http://localhost/form>", "- button \"Save\" [ref=e3]"])

    let scoped = await BrowserAutomationRunner(page: page).run([.snapshot(full: true, scope: "e2")])
    #expect(scoped.lines == ["page: Form <http://localhost/form>", "- heading \"Title\" [ref=e2]"])

    let failed = await BrowserAutomationRunner(page: page).run([.snapshot(full: false, scope: "e9")])
    #expect(failed.failure == "Ref e9 is not on the page now. Run `snapshot` for current refs.")
  }

  @Test func aSnapshotAfterAnActionReplacesTheChangeReport() async {
    let page = FakePage(snapshots: [Self.before, Self.after])
    let result = await BrowserAutomationRunner(page: page).run([Self.click, .snapshot(full: false, scope: nil)])
    #expect(page.calls == [.snapshot, Self.clicked, .settle, .snapshot])
    #expect(result.lines == ["done", "page: Form <http://localhost/form>", "- button \"Save\" [ref=e1]"])
  }

  @Test func aPageWithoutControlsSaysHowToReadIt() async {
    let page = FakePage(snapshots: ["- paragraph [ref=e1]: hello"])
    let result = await BrowserAutomationRunner(page: page).run([.snapshot(full: false, scope: nil)])
    #expect(result.lines.last == "(no interactive elements. Use `snapshot --full` for the page content.)")
  }

  @Test func readingStepsPrintTheirResultWithoutAChangeReport() async {
    let page = FakePage(snapshots: [Self.before])
    page.console = ["error: boom", "log: ready"]
    let result = await BrowserAutomationRunner(page: page).run([
      .evaluate(source: "document.title"),
      .console(clear: true),
      .screenshot(path: "/tmp/page.png"),
      .console(clear: false),
    ])
    #expect(page.calls == [.evaluate("document.title"), .settle, .screenshot("/tmp/page.png")])
    #expect(
      result.lines == [
        "\"document.title\"", "error: boom\nlog: ready", "saved /tmp/page.png", "(no console messages)",
      ])
    #expect(result.failure == nil)
  }

  @Test func everythingTheRunnerPrintsIsRedacted() async {
    let page = FakePage(snapshots: ["- status [ref=e1]: idle", "- status [ref=e1]: you typed hunter2"])
    page.console = ["log: password is hunter2"]
    page.title = "Account hunter2"
    page.onPerform = { (action) throws(BrowserAutomationError) -> String? in
      if case .fill = action {
        throw .rejected("field rejects hunter2")
      }
      return "clicked link \"hunter2\""
    }
    let printed = await BrowserAutomationRunner(page: page).run([
      Self.click, .evaluate(source: "hunter2"), .console(clear: false), .snapshot(full: true, scope: nil),
    ])
    #expect(
      printed.lines == [
        "clicked link \"[masked]\"", "\"[masked]\"", "log: password is [masked]",
        "page: Account [masked] <http://localhost/form>", "- status [ref=e1]: you typed [masked]",
      ])

    let failed = await BrowserAutomationRunner(page: page, reportsChanges: false).run([
      .fill(target: "e1", text: "x")
    ])
    #expect(failed.failure == "field rejects [masked]")

    page.pendingDialog = BrowserPageDialog(kind: .alert, message: "saved hunter2")
    let blocked = await BrowserAutomationRunner(page: page).run([Self.click])
    #expect(blocked.failure?.contains("alert \"saved [masked]\"") == true)
  }

  @Test func anActionThatOpensADialogSaysSoAndStopsTheBatch() async {
    let page = FakePage(snapshots: [Self.before])
    page.onPerform = { (_) throws(BrowserAutomationError) -> String? in
      page.pendingDialog = Self.confirm
      throw .dialogOpened(Self.confirm)
    }
    let single = await BrowserAutomationRunner(page: page).run([Self.click])
    #expect(
      single.lines == [
        "a page dialog opened: confirm \"Delete it?\"", "Answer it with `dialog accept` or `dialog dismiss`.",
      ])
    #expect(single.failure == nil)

    page.pendingDialog = nil
    let batch = await BrowserAutomationRunner(page: page).run([Self.click, Self.click])
    #expect(batch.failure == "Stopped before step 2: a page dialog is open.")
  }

  @Test func anOpenDialogBlocksPageStepsUntilItIsAnswered() async {
    let page = FakePage(snapshots: [Self.after])
    page.lastSnapshot = BrowserPageSnapshot(text: Self.before, url: page.url, title: page.title)
    page.pendingDialog = Self.confirm
    let blocked = await BrowserAutomationRunner(page: page).run([Self.click])
    #expect(
      blocked.failure
        == "A page dialog is open: confirm \"Delete it?\". Answer it with `dialog accept` or `dialog dismiss`.")
    #expect(page.calls.isEmpty)

    let answered = await BrowserAutomationRunner(page: page).run([.dialog(.accept(text: nil))])
    #expect(page.calls == [.answer(.accept(text: nil)), .settle, .snapshot])
    #expect(answered.lines == ["accepted confirm \"Delete it?\"", "changed:\n- status [ref=e2]: saved"])

    let none = await BrowserAutomationRunner(page: page, reportsChanges: false).run([.dialog(.dismiss)])
    #expect(none.failure == "No page dialog is open.")
  }
}
