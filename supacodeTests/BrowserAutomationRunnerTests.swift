import Foundation
import Testing

@testable import supacode

@MainActor
struct BrowserAutomationRunnerTests {
  private final class FakePage: BrowserAutomationPage {
    var isLoadingPage = false
    var documentGeneration = 1
    var snapshotBaseline: BrowserSnapshotBaseline?
    var commands: [String] = []
    var loadedURLs: [URL] = []
    var snapshots: [String]
    var url = "http://localhost/form"
    var title = "Form"
    var onCommand: (String, [String: Any]) throws(BrowserAutomationError) -> BrowserDriverReply? = { _, _ in nil }

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

    func drive(
      _ command: String,
      _ arguments: [String: Any],
      timeout: Duration
    ) async throws(BrowserAutomationError) -> BrowserDriverReply {
      await Task.yield()
      commands.append(command)
      if let reply = try onCommand(command, arguments) {
        return reply
      }
      switch command {
      case "snapshot":
        let text = snapshots.count > 1 ? snapshots.removeFirst() : snapshots[0]
        return BrowserDriverReply(text: text, url: url, title: title)
      case "settle":
        return BrowserDriverReply()
      default:
        return BrowserDriverReply(ack: "\(command) done")
      }
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

  private static func step(_ verb: BrowserAutomationStep.Verb, target: String? = "e1") -> BrowserAutomationStep {
    BrowserAutomationStep(verb: verb, target: target)
  }

  @Test func anActionPrintsItsAcknowledgementAndWhatChanged() async {
    let page = FakePage(snapshots: [Self.before, Self.after])
    let result = await BrowserAutomationRunner(page: page).run([Self.step(.click)])
    #expect(page.commands == ["snapshot", "click", "settle", "snapshot"])
    #expect(result == BrowserAutomationResult(lines: ["click done", "changed:\n- status [ref=e2]: saved"]))
    #expect(page.snapshotBaseline == BrowserSnapshotBaseline(text: Self.after, url: page.url))
  }

  @Test func aQuietActionDoesNotReadThePage() async {
    let page = FakePage(snapshots: [Self.before])
    let result = await BrowserAutomationRunner(page: page, reportsChanges: false).run([Self.step(.click)])
    #expect(page.commands == ["click"])
    #expect(result.lines == ["click done"])
  }

  @Test func anUnchangedPageSaysSo() async {
    let page = FakePage(snapshots: [Self.before])
    let result = await BrowserAutomationRunner(page: page).run([Self.step(.click)])
    #expect(result.lines == ["click done", "no visible change"])
  }

  @Test func aKnownBaselineIsNotReadAgain() async {
    let page = FakePage(snapshots: [Self.after])
    page.snapshotBaseline = BrowserSnapshotBaseline(text: Self.before, url: page.url)
    let result = await BrowserAutomationRunner(page: page).run([Self.step(.click)])
    #expect(page.commands == ["click", "settle", "snapshot"])
    #expect(result.lines == ["click done", "changed:\n- status [ref=e2]: saved"])
  }

  @Test func aBatchSettlesBetweenStepsAndReportsOnce() async {
    let page = FakePage(snapshots: [Self.before, Self.after])
    var fill = Self.step(.fill)
    fill.text = "ada"
    let result = await BrowserAutomationRunner(page: page).run([fill, Self.step(.click)])
    #expect(page.commands == ["snapshot", "fill", "settle", "click", "settle", "snapshot"])
    #expect(result.lines == ["fill done", "click done", "changed:\n- status [ref=e2]: saved"])
  }

  @Test func aQuietBatchSettlesOnlyBetweenSteps() async {
    let page = FakePage(snapshots: [Self.before])
    let result = await BrowserAutomationRunner(page: page, reportsChanges: false).run([
      Self.step(.click), Self.step(.click),
    ])
    #expect(page.commands == ["click", "settle", "click"])
    #expect(result.lines == ["click done", "click done"])
  }

  @Test func aNavigationPrintsTheNewPage() async {
    let page = FakePage(snapshots: [Self.before, "- heading \"Done\" [ref=p2e1]\n- link \"Home\" [ref=p2e2]"])
    page.onCommand = { command, _ in
      if command == "settle" {
        page.documentGeneration = 2
        page.url = "http://localhost/done"
        page.title = "Done"
      }
      return nil
    }
    let result = await BrowserAutomationRunner(page: page).run([Self.step(.click)])
    #expect(
      result.lines == ["click done", "navigated: Done <http://localhost/done>", "- link \"Home\" [ref=p2e2]"])
  }

  @Test func aNewURLInTheSameDocumentIsReported() async {
    let page = FakePage(snapshots: [Self.before, Self.after])
    page.onCommand = { command, _ in
      if command == "settle" {
        page.url = "http://localhost/form#saved"
      }
      return nil
    }
    let result = await BrowserAutomationRunner(page: page).run([Self.step(.click)])
    #expect(
      result.lines == ["click done", "url: http://localhost/form#saved", "changed:\n- status [ref=e2]: saved"])
  }

  @Test func aFailingStepStopsTheBatchAndIsNamed() async {
    let page = FakePage(snapshots: [Self.before])
    page.onCommand = { (command, _) throws(BrowserAutomationError) -> BrowserDriverReply? in
      if command == "click" {
        throw .rejected("button \"Save\" is disabled.")
      }
      return nil
    }
    var fill = Self.step(.fill)
    fill.text = "ada"
    let result = await BrowserAutomationRunner(page: page).run([fill, Self.step(.click), Self.step(.press)])
    #expect(page.commands == ["snapshot", "fill", "settle", "click"])
    #expect(result.lines == ["fill done"])
    #expect(result.failure == "step 2 (click): button \"Save\" is disabled.")
  }

  @Test func aSingleFailingStepReportsOnlyTheReason() async {
    let page = FakePage(snapshots: [Self.before])
    let result = await BrowserAutomationRunner(page: page).run([Self.step(.click, target: nil)])
    #expect(result.failure == "Missing a target.")
    #expect(page.commands == ["snapshot"])
  }

  @Test func aTimedOutActionSaysItMayHaveHappened() async {
    let page = FakePage(snapshots: [Self.before])
    page.onCommand = { (command, _) throws(BrowserAutomationError) -> BrowserDriverReply? in
      if command == "click" {
        throw .timedOut
      }
      return nil
    }
    let result = await BrowserAutomationRunner(page: page, reportsChanges: false).run([Self.step(.click)])
    #expect(result.failure == "Timed out. The action may have happened. A page dialog may be blocking the page.")
  }

  @Test func aWaitStartsOverWhenTheDocumentChanges() async {
    let page = FakePage(snapshots: [Self.before])
    var attempts = 0
    page.onCommand = { (command, arguments) throws(BrowserAutomationError) -> BrowserDriverReply? in
      guard command == "wait" else { return nil }
      attempts += 1
      #expect(arguments["text"] as? String == "Welcome")
      if attempts == 1 {
        throw .contextLost
      }
      return BrowserDriverReply(ack: "found text \"Welcome\"")
    }
    var wait = Self.step(.wait, target: nil)
    wait.text = "Welcome"
    let result = await BrowserAutomationRunner(page: page, reportsChanges: false).run([wait])
    #expect(attempts == 2)
    #expect(result.lines == ["found text \"Welcome\""])
  }

  @Test func navigateLoadsTheResolvedAddress() async {
    let page = FakePage(snapshots: [Self.before])
    var navigate = Self.step(.navigate, target: nil)
    navigate.url = "localhost:3000/login"
    let result = await BrowserAutomationRunner(page: page, reportsChanges: false).run([navigate])
    #expect(page.loadedURLs == [URL(string: "http://localhost:3000/login")!])
    #expect(result.lines == ["opened http://localhost:3000/login"])
  }

  @Test func snapshotPrintsInteractiveElementsUnderAPageLine() async {
    let page = FakePage(snapshots: ["- generic [ref=e1]:\n  - heading \"Title\" [ref=e2]\n  - button \"Save\" [ref=e3]"]
    )
    let result = await BrowserAutomationRunner(page: page).run([Self.step(.snapshot, target: nil)])
    #expect(result.lines == ["page: Form <http://localhost/form>", "- button \"Save\" [ref=e3]"])

    var full = Self.step(.snapshot, target: nil)
    full.full = true
    full.scope = "e2"
    let scoped = await BrowserAutomationRunner(page: page).run([full])
    #expect(scoped.lines == ["page: Form <http://localhost/form>", "- heading \"Title\" [ref=e2]"])

    var missing = Self.step(.snapshot, target: nil)
    missing.scope = "e9"
    let failed = await BrowserAutomationRunner(page: page).run([missing])
    #expect(failed.failure == "Ref e9 is not on the page now. Run `snapshot` for current refs.")
  }

  @Test func aSnapshotAfterAnActionReplacesTheChangeReport() async {
    let page = FakePage(snapshots: [Self.before, Self.after])
    let result = await BrowserAutomationRunner(page: page).run([Self.step(.click), Self.step(.snapshot, target: nil)])
    #expect(page.commands == ["snapshot", "click", "settle", "snapshot"])
    #expect(result.lines == ["click done", "page: Form <http://localhost/form>", "- button \"Save\" [ref=e1]"])
  }

  @Test func aPageWithoutControlsSaysHowToReadIt() async {
    let page = FakePage(snapshots: ["- paragraph [ref=e1]: hello"])
    let result = await BrowserAutomationRunner(page: page).run([Self.step(.snapshot, target: nil)])
    #expect(result.lines.last == "(no interactive elements. Use `snapshot --full` for the page content.)")
  }
}
