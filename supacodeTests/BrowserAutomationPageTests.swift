import AppKit
import Foundation
import Testing
import WebKit

@testable import supacode

@MainActor
@Suite(.serialized)
struct BrowserAutomationPageTests {
  private final class WebPage: NSObject, BrowserAutomationPage, WKNavigationDelegate {
    let webView: WKWebView
    let session = BrowserAutomationSession()
    let directory: URL

    init(files: [String: String]) throws {
      directory = FileManager.default.temporaryDirectory.appending(path: "browser-automation-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      for (name, html) in files {
        try html.write(to: directory.appending(path: name), atomically: true, encoding: .utf8)
      }
      let configuration = WKWebViewConfiguration()
      configuration.websiteDataStore = .nonPersistent()
      webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
      super.init()
      webView.navigationDelegate = self
    }

    nonisolated deinit {}

    var isLoadingPage: Bool { webView.isLoading }
    var documentGeneration: Int { session.generation }
    var pendingDialog: BrowserPageDialog? { nil }
    var lastSnapshot: BrowserPageSnapshot? {
      get { session.lastSnapshot }
      set { session.lastSnapshot = newValue }
    }

    func open(_ name: String) async {
      webView.loadFileURL(directory.appending(path: name), allowingReadAccessTo: directory)
      _ = await waitUntilLoaded(timeout: .seconds(20))
    }

    func loadPage(_ url: URL) {
      webView.loadFileURL(url, allowingReadAccessTo: directory)
    }

    func waitUntilLoaded(timeout: Duration) async -> Bool {
      await session.waitUntilLoaded(webView, timeout: timeout)
    }

    func snapshot() async throws(BrowserAutomationError) -> BrowserPageSnapshot {
      try await session.snapshot(in: webView)
    }

    func perform(_ action: BrowserPageAction) async throws(BrowserAutomationError) -> String {
      try await session.perform(action, in: webView)
    }

    func settle() async {
      await session.settle(in: webView)
    }

    func evaluate(_ source: String) async throws(BrowserAutomationError) -> String {
      try await session.evaluate(source, in: webView)
    }

    func saveScreenshot(to path: String?) async throws(BrowserAutomationError) -> String {
      try await BrowserScreenshot.save(webView, to: path)
    }

    func consoleMessages(clearing: Bool) -> [String] {
      session.console.drain(clearing: clearing)
    }

    func answerDialog(_ answer: BrowserDialogAnswer) -> BrowserPageDialog? {
      nil
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
      session.documentChanged()
    }

    func pageValue(_ script: String) async -> String? {
      try? await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page) as? String
    }

    func remove() {
      try? FileManager.default.removeItem(at: directory)
    }
  }

  private static let form = """
    <!doctype html><title>Sign In</title>
    <form id="login">
      <label>Email <input id="email" type="email"></label>
      <label>Password <input id="password" type="password"></label>
      <label><input id="remember" type="checkbox"> Remember me</label>
      <label>Plan <select id="plan"><option value="free">Free</option><option value="pro">Pro</option></select></label>
      <button type="submit">Sign in</button>
    </form>
    <p id="status" role="status"></p>
    <form action="done.html"><label>Search <input name="q"></label></form>
    <a href="done.html">Leave</a>
    <script>
      document.getElementById('login').addEventListener('submit', function (event) {
        event.preventDefault();
        document.getElementById('status').textContent = 'Welcome ' + document.getElementById('email').value
          + ' ' + document.getElementById('plan').value + ' ' + document.getElementById('remember').checked;
      });
    </script>
    """
  private static let echo = """
    <!doctype html><title>Echo</title>
    <label>Secret <input id="secret" type="password"></label>
    <div style="pointer-events: none"><label>Pin <input id="pin" type="password"></label></div>
    <p id="status" role="status"></p>
    <form action="done.html"><label>Token <input name="token" type="password"></label><button>Send</button></form>
    <div id="cover" style="position:fixed;inset:0"></div>
    <script>
      document.getElementById('secret').addEventListener('input', function (event) {
        document.getElementById('status').textContent = 'You typed ' + event.target.value;
        document.title = 'Echo ' + event.target.value;
      });
    </script>
    """
  private static let done = "<!doctype html><title>Done</title><h1>Done</h1><a href=\"form.html\">Back</a>"
  private static let quiet = { (page: WebPage) in BrowserAutomationRunner(page: page, reportsChanges: false) }
  private static let snapshot = BrowserAutomationStep.snapshot(full: false, scope: nil)

  @Test(.timeLimit(.minutes(1)))
  func aSnapshotListsControlsWithRefsAndMasksPasswords() async throws {
    let page = try WebPage(files: ["form.html": Self.form])
    defer { page.remove() }
    await page.open("form.html")
    _ = await Self.quiet(page).run([.fill(target: "role=textbox[name=\"Password\"]", text: "hunter2")])
    let result = await BrowserAutomationRunner(page: page).run([Self.snapshot])
    let text = result.lines.joined(separator: "\n")
    #expect(result.failure == nil)
    #expect(text.contains("page: Sign In <file://"))
    #expect(text.contains("- textbox \"Email\" [ref=e"))
    #expect(text.contains("- textbox \"Password\" [ref=e"))
    #expect(text.contains("[masked]"))
    #expect(!text.contains("hunter2"))
    #expect(text.contains("- button \"Sign in\" [ref=e"))
    #expect(await page.pageValue("return document.getElementById('password').value") == "hunter2")

    let cleared = await Self.quiet(page).run([.fill(target: "role=textbox[name=\"Password\"]", text: "")])
    #expect(cleared.failure == nil)
    #expect(await page.pageValue("return document.getElementById('password').value") == "")
  }

  @Test(.timeLimit(.minutes(1)))
  func aPasswordIsRedactedWhereverThePageRepeatsIt() async throws {
    let page = try WebPage(files: ["echo.html": Self.echo, "done.html": Self.done])
    defer { page.remove() }
    await page.open("echo.html")
    let filled = await BrowserAutomationRunner(page: page).run([
      .fill(target: "#secret", text: "hunter2"),
      .fill(target: "#pin", text: "42"),
    ])
    #expect(filled.failure == nil)
    let full = await BrowserAutomationRunner(page: page).run([.snapshot(full: true, scope: nil)])
    let output = (filled.lines + full.lines).joined(separator: "\n")
    #expect(!output.contains("hunter2"))
    #expect(output.contains("You typed [masked]"))
    #expect(output.contains("page: Echo [masked] <file://"))
    #expect(output.contains("textbox \"Pin\": \"[masked]\""))
    #expect(!output.contains(": 42"))

    let covered = await Self.quiet(page).run([.click(target: "#secret")])
    #expect(covered.failure?.contains("is covered by") == true)
    #expect(covered.failure?.contains("hunter2") == false)

    let read = await Self.quiet(page).run([.evaluate(source: "document.getElementById('secret').value")])
    #expect(read.lines == ["\"[masked]\""])

    _ = await page.pageValue("document.getElementById('cover').remove(); return ''")
    let sent = await BrowserAutomationRunner(page: page).run([
      .fill(target: "role=textbox[name=\"Token\"]", text: "hunter2"),
      .click(target: "role=button[name=\"Send\"]"),
    ])
    let navigated = sent.lines.joined(separator: "\n")
    #expect(navigated.contains("navigated: Done <file://"))
    #expect(navigated.contains("token=[masked]"))
    #expect(!navigated.contains("hunter2"))
  }

  @Test(.timeLimit(.minutes(1)))
  func aBatchFillsTheFormAndReportsWhatChanged() async throws {
    let page = try WebPage(files: ["form.html": Self.form])
    defer { page.remove() }
    await page.open("form.html")
    let result = await BrowserAutomationRunner(page: page).run([
      .fill(target: "role=textbox[name=\"Email\"]", text: "ada@example.com"),
      .click(target: "role=checkbox[name=\"Remember me\"]"),
      .select(target: "role=combobox[name=\"Plan\"]", option: "Pro"),
      .click(target: "role=button[name=\"Sign in\"]"),
    ])
    #expect(result.failure == nil)
    #expect(
      await page.pageValue("return document.getElementById('status').textContent")
        == "Welcome ada@example.com pro true")
    let report = try #require(result.lines.last)
    #expect(report.contains("Welcome ada@example.com pro true"))
    #expect(report.contains("- checkbox \"Remember me\" [checked]"))
    #expect(result.lines.first?.hasPrefix("filled textbox \"Email\"") == true)
  }

  @Test(.timeLimit(.minutes(1)))
  func enterSubmitsAFormAndOldRefsFailOnTheNewPage() async throws {
    let page = try WebPage(files: ["form.html": Self.form, "done.html": Self.done])
    defer { page.remove() }
    await page.open("form.html")
    let first = await BrowserAutomationRunner(page: page).run([Self.snapshot])
    let searchLine = try #require(
      first.lines.joined(separator: "\n").split(separator: "\n").first { $0.contains("textbox \"Search\"") })
    let oldRef = try #require(BrowserSnapshotText.parse(String(searchLine)).first?.ref)
    let result = await BrowserAutomationRunner(page: page).run([
      .fill(target: oldRef, text: "cats"),
      .press(key: "Enter", target: nil),
    ])
    #expect(result.failure == nil)
    let report = result.lines.joined(separator: "\n")
    #expect(report.contains("navigated: Done <file://"))
    #expect(report.contains("done.html?q=cats"))
    #expect(report.contains("- link \"Back\" [ref=p2e"))

    let stale = await BrowserAutomationRunner(page: page).run([.click(target: oldRef)])
    #expect(stale.failure == "Ref \(oldRef) is from a page that is gone. Run `snapshot` for current refs.")
  }

  @Test(.timeLimit(.minutes(1)))
  func aNewDocumentForgetsWhatWasReadOnTheOldOne() async throws {
    let page = try WebPage(files: ["form.html": Self.form, "done.html": Self.done])
    defer { page.remove() }
    await page.open("form.html")
    _ = await BrowserAutomationRunner(page: page).run([Self.snapshot])
    #expect(page.lastSnapshot != nil)
    await page.open("done.html")
    #expect(page.lastSnapshot == nil)
    let result = await BrowserAutomationRunner(page: page).run([.press(key: "Tab", target: nil)])
    #expect(result.lines == ["pressed Tab", "no visible change"])
  }

  @Test(.timeLimit(.minutes(1)))
  func aCallPendingAcrossANavigationIsAbandoned() async throws {
    let page = try WebPage(files: ["form.html": Self.form, "done.html": Self.done])
    defer { page.remove() }
    await page.open("form.html")
    _ = try await page.perform(.click(target: "role=link[name=\"Leave\"]"))
    await #expect(throws: BrowserAutomationError.contextLost) {
      _ = try await page.perform(.wait(.text("never shown"), timeout: .seconds(30)))
    }
    #expect(await page.waitUntilLoaded(timeout: .seconds(20)))
    #expect(try await page.snapshot().title == "Done")
    #expect(page.documentGeneration == 2)
  }

  @Test(.timeLimit(.minutes(1)))
  func problemsNameTheElementAndTheNextStep() async throws {
    let page = try WebPage(files: ["form.html": Self.form])
    defer { page.remove() }
    await page.open("form.html")
    let ambiguous = await Self.quiet(page).run([.click(target: "role=textbox")])
    #expect(ambiguous.failure?.hasPrefix("3 elements match \"role=textbox\". Use a ref or a narrower locator:") == true)
    let missing = await Self.quiet(page).run([.click(target: "text=Nope")])
    #expect(missing.failure == "No element matches \"text=Nope\".")
    let wrongKind = await Self.quiet(page).run([.fill(target: "role=combobox[name=\"Plan\"]", text: "Pro")])
    #expect(wrongKind.failure?.hasSuffix("is a select. Use `select` with an option label or value.") == true)
    let stillVisible = await Self.quiet(page).run([
      .wait(.target("role=textbox", hidden: true), timeout: .milliseconds(300))
    ])
    #expect(stillVisible.failure?.hasPrefix("3 elements match \"role=textbox\".") == true)
    let gone = await Self.quiet(page).run([.wait(.target("text=Nope", hidden: true), timeout: .seconds(10))])
    #expect(gone.lines == ["found text=Nope to be hidden"])
    let timedOut = await Self.quiet(page).run([.wait(.text("Never shown"), timeout: .milliseconds(300))])
    #expect(timedOut.failure == "Timed out after 0.3s waiting for text \"Never shown\".")
  }

  @Test(.timeLimit(.minutes(1)))
  func evalRunsInThePageAndPrintsJSON() async throws {
    let page = try WebPage(files: ["form.html": Self.form])
    defer { page.remove() }
    await page.open("form.html")
    let result = await Self.quiet(page).run([
      .evaluate(source: "document.title"),
      .evaluate(source: "({ fields: document.querySelectorAll('input').length })"),
      .evaluate(source: "const plan = document.getElementById('plan'); return await Promise.resolve(plan.value)"),
      .evaluate(source: "window.nothingHere"),
    ])
    #expect(result.failure == nil)
    #expect(result.lines == ["\"Sign In\"", "{\n  \"fields\": 4\n}", "\"free\"", "undefined"])

    let thrown = await Self.quiet(page).run([.evaluate(source: "missingFunction()")])
    #expect(thrown.failure?.hasPrefix("The script failed: ") == true)
    #expect(thrown.failure?.contains("missingFunction") == true)
  }

  @Test(.timeLimit(.minutes(1)))
  func consoleCollectsWhatThePageLogs() async throws {
    let page = try WebPage(files: ["form.html": Self.form])
    defer { page.remove() }
    await page.open("form.html")
    let result = await Self.quiet(page).run([
      .evaluate(source: "console.log('ready', { count: 2 }); console.error('broken'); return 1"),
      .console(clear: true),
      .console(clear: false),
    ])
    #expect(result.failure == nil)
    #expect(result.lines.dropLast().last == "log: ready {\"count\":2}\nerror: broken")
    #expect(result.lines.last == "(no console messages)")
  }

  @Test(.timeLimit(.minutes(1)))
  func screenshotWritesAPNG() async throws {
    let page = try WebPage(files: ["form.html": Self.form])
    defer { page.remove() }
    await page.open("form.html")
    let path = page.directory.appending(path: "shots/page.png").path(percentEncoded: false)
    let result = await Self.quiet(page).run([.screenshot(path: path)])
    #expect(result.failure == nil)
    #expect(result.lines == ["saved \(path)"])
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    #expect(data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
  }

  private static func makeContent(_ html: String) -> BrowserContent {
    let content = BrowserContent(
      id: ContentID(),
      initialState: BrowserContentState(
        url: URL(string: "data:text/html," + (html.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""))
      ),
      callbacks: BrowserContentCallbacks(),
      makeWebView: {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return BrowserWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
      }
    )
    content.startSession(at: .fallback)
    return content
  }

  @Test(.timeLimit(.minutes(1)))
  func aBrowserTabStaysAwakeWhileAutomationUsesIt() async throws {
    let content = Self.makeContent("<title>Fixture</title><button>Go</button>")
    defer { content.tearDown() }
    #expect(content.isHibernatable)
    #expect(await content.waitUntilLoaded(timeout: .seconds(20)))
    let result = await content.automation.serialized {
      #expect(!content.isHibernatable)
      return await BrowserAutomationRunner(page: content).run([Self.snapshot])
    }
    #expect(result.lines.first?.hasPrefix("page: Fixture <data:text/html,") == true)
    #expect(result.lines.last?.hasPrefix("- button \"Go\" [ref=e") == true)
    #expect(!content.isHibernatable)
  }

  @Test(.timeLimit(.minutes(1)))
  func aDialogStopsThePageUntilAutomationAnswersIt() async throws {
    let script = "document.getElementById('out').textContent = confirm('Delete it?') ? 'deleted' : 'kept'"
    let content = Self.makeContent(
      "<title>Dialog</title><button onclick=\"\(script)\">Delete</button><p id='out' role='status'>idle</p>")
    defer { content.tearDown() }
    #expect(await content.waitUntilLoaded(timeout: .seconds(20)))
    let delete = BrowserAutomationStep.click(target: "role=button[name=\"Delete\"]")

    let opened = await BrowserAutomationRunner(page: content).run([delete])
    #expect(opened.failure == nil)
    #expect(
      opened.lines == [
        "a page dialog opened: confirm \"Delete it?\"", "Answer it with `dialog accept` or `dialog dismiss`.",
      ])
    #expect(content.pendingDialog == BrowserPageDialog(kind: .confirm, message: "Delete it?"))

    let blocked = await BrowserAutomationRunner(page: content).run([Self.snapshot])
    #expect(blocked.failure?.hasPrefix("A page dialog is open: confirm \"Delete it?\".") == true)

    let accepted = await BrowserAutomationRunner(page: content).run([.dialog(.accept(text: nil))])
    #expect(accepted.failure == nil)
    #expect(accepted.lines.first == "accepted confirm \"Delete it?\"")
    #expect(accepted.lines.last?.hasPrefix("changed:\n- status [ref=e") == true)
    #expect(accepted.lines.last?.hasSuffix(": deleted") == true)
    #expect(content.pendingDialog == nil)

    _ = await BrowserAutomationRunner(page: content).run([delete])
    let dismissed = await BrowserAutomationRunner(page: content).run([.dialog(.dismiss)])
    #expect(dismissed.lines.last?.hasSuffix(": kept") == true)
  }
}
