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
    var snapshotBaseline: BrowserSnapshotBaseline? {
      get { session.baseline }
      set { session.baseline = newValue }
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

    func drive(
      _ command: String,
      _ arguments: [String: Any],
      timeout: Duration
    ) async throws(BrowserAutomationError) -> BrowserDriverReply {
      try await session.run(command, arguments, in: webView, timeout: timeout)
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

  private static func step(
    _ verb: BrowserAutomationStep.Verb,
    _ target: String? = nil,
    text: String? = nil,
    key: String? = nil,
    option: String? = nil
  ) -> BrowserAutomationStep {
    BrowserAutomationStep(verb: verb, target: target, text: text, key: key, option: option)
  }

  @Test(.timeLimit(.minutes(1)))
  func aSnapshotListsControlsWithRefsAndMasksPasswords() async throws {
    let page = try WebPage(files: ["form.html": Self.form])
    defer { page.remove() }
    await page.open("form.html")
    _ = await BrowserAutomationRunner(page: page, reportsChanges: false).run([
      Self.step(.fill, "role=textbox[name=\"Password\"]", text: "hunter2")
    ])
    let result = await BrowserAutomationRunner(page: page).run([Self.step(.snapshot)])
    let text = result.lines.joined(separator: "\n")
    #expect(result.failure == nil)
    #expect(text.contains("page: Sign In <file://"))
    #expect(text.contains("- textbox \"Email\" [ref=e"))
    #expect(text.contains("- textbox \"Password\" [ref=e"))
    #expect(text.contains("[masked]"))
    #expect(!text.contains("hunter2"))
    #expect(text.contains("- button \"Sign in\" [ref=e"))
    #expect(await page.pageValue("return document.getElementById('password').value") == "hunter2")

    let cleared = await BrowserAutomationRunner(page: page, reportsChanges: false).run([
      Self.step(.fill, "role=textbox[name=\"Password\"]", text: "")
    ])
    #expect(cleared.failure == nil)
    #expect(await page.pageValue("return document.getElementById('password').value") == "")
  }

  @Test(.timeLimit(.minutes(1)))
  func aPasswordIsRedactedWhereverThePageRepeatsIt() async throws {
    let page = try WebPage(files: ["echo.html": Self.echo, "done.html": Self.done])
    defer { page.remove() }
    await page.open("echo.html")
    let filled = await BrowserAutomationRunner(page: page).run([
      Self.step(.fill, "#secret", text: "hunter2"),
      Self.step(.fill, "#pin", text: "42"),
    ])
    #expect(filled.failure == nil)
    let full = await BrowserAutomationRunner(page: page).run([BrowserAutomationStep(verb: .snapshot, full: true)])
    let output = (filled.lines + full.lines).joined(separator: "\n")
    #expect(!output.contains("hunter2"))
    #expect(output.contains("You typed [masked]"))
    #expect(output.contains("page: Echo [masked] <file://"))
    #expect(output.contains("textbox \"Pin\": \"[masked]\""))
    #expect(!output.contains(": 42"))

    let covered = await BrowserAutomationRunner(page: page, reportsChanges: false).run([Self.step(.click, "#secret")])
    #expect(covered.failure?.contains("is covered by") == true)
    #expect(covered.failure?.contains("hunter2") == false)

    _ = await page.pageValue("document.getElementById('cover').remove(); return ''")
    let sent = await BrowserAutomationRunner(page: page).run([
      Self.step(.fill, "role=textbox[name=\"Token\"]", text: "hunter2"),
      Self.step(.click, "role=button[name=\"Send\"]"),
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
      Self.step(.fill, "role=textbox[name=\"Email\"]", text: "ada@example.com"),
      Self.step(.click, "role=checkbox[name=\"Remember me\"]"),
      Self.step(.select, "role=combobox[name=\"Plan\"]", option: "Pro"),
      Self.step(.click, "role=button[name=\"Sign in\"]"),
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
    let first = await BrowserAutomationRunner(page: page).run([Self.step(.snapshot)])
    let searchLine = try #require(
      first.lines.joined(separator: "\n").split(separator: "\n").first { $0.contains("textbox \"Search\"") })
    let oldRef = try #require(BrowserSnapshotText.parse(String(searchLine)).first?.ref)
    let result = await BrowserAutomationRunner(page: page).run([
      Self.step(.fill, oldRef, text: "cats"),
      Self.step(.press, key: "Enter"),
    ])
    #expect(result.failure == nil)
    let report = result.lines.joined(separator: "\n")
    #expect(report.contains("navigated: Done <file://"))
    #expect(report.contains("done.html?q=cats"))
    #expect(report.contains("- link \"Back\" [ref=p2e"))

    let stale = await BrowserAutomationRunner(page: page).run([Self.step(.click, oldRef)])
    #expect(stale.failure == "Ref \(oldRef) is from a page that is gone. Run `snapshot` for current refs.")
  }

  @Test(.timeLimit(.minutes(1)))
  func aCallPendingAcrossANavigationIsAbandoned() async throws {
    let page = try WebPage(files: ["form.html": Self.form, "done.html": Self.done])
    defer { page.remove() }
    await page.open("form.html")
    _ = try await page.drive("click", ["target": "role=link[name=\"Leave\"]"], timeout: .seconds(10))
    await #expect(throws: BrowserAutomationError.contextLost) {
      _ = try await page.drive("settle", ["quietMs": 30_000, "maxMs": 30_000], timeout: .seconds(40))
    }
    #expect(await page.waitUntilLoaded(timeout: .seconds(20)))
    let reply = try await page.drive("snapshot", [:], timeout: .seconds(10))
    #expect(reply.title == "Done")
    #expect(page.documentGeneration == 2)
  }

  @Test(.timeLimit(.minutes(1)))
  func problemsNameTheElementAndTheNextStep() async throws {
    let page = try WebPage(files: ["form.html": Self.form])
    defer { page.remove() }
    await page.open("form.html")
    let ambiguous = await BrowserAutomationRunner(page: page, reportsChanges: false).run([
      Self.step(.click, "role=textbox")
    ])
    #expect(ambiguous.failure?.hasPrefix("3 elements match \"role=textbox\". Use a ref or a narrower locator:") == true)
    let missing = await BrowserAutomationRunner(page: page, reportsChanges: false).run([Self.step(.click, "text=Nope")])
    #expect(missing.failure == "No element matches \"text=Nope\".")
    let wrongKind = await BrowserAutomationRunner(page: page, reportsChanges: false).run([
      Self.step(.fill, "role=combobox[name=\"Plan\"]", text: "Pro")
    ])
    #expect(wrongKind.failure?.hasSuffix("is a select. Use `select` with an option label or value.") == true)
    var hiddenButAmbiguous = Self.step(.wait, "role=textbox")
    hiddenButAmbiguous.hidden = true
    hiddenButAmbiguous.timeout = 0.3
    let stillVisible = await BrowserAutomationRunner(page: page, reportsChanges: false).run([hiddenButAmbiguous])
    #expect(stillVisible.failure?.hasPrefix("3 elements match \"role=textbox\".") == true)
    var hiddenAndGone = Self.step(.wait, "text=Nope")
    hiddenAndGone.hidden = true
    let gone = await BrowserAutomationRunner(page: page, reportsChanges: false).run([hiddenAndGone])
    #expect(gone.lines == ["found text=Nope to be hidden"])
    var wait = Self.step(.wait)
    wait.text = "Never shown"
    wait.timeout = 0.3
    let timedOut = await BrowserAutomationRunner(page: page, reportsChanges: false).run([wait])
    #expect(timedOut.failure == "Timed out after 0.3s waiting for text \"Never shown\".")
  }

  @Test(.timeLimit(.minutes(1)))
  func aBrowserTabStaysAwakeWhileAutomationUsesIt() async throws {
    let content = BrowserContent(
      id: ContentID(),
      initialState: BrowserContentState(url: URL(string: "data:text/html,<title>Fixture</title><button>Go</button>")),
      callbacks: BrowserContentCallbacks(),
      makeWebView: {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return BrowserWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
      }
    )
    content.startSession(at: .fallback)
    defer { content.tearDown() }
    #expect(content.isHibernatable)
    #expect(await content.waitUntilLoaded(timeout: .seconds(20)))
    let result = await content.automation.serialized {
      #expect(!content.isHibernatable)
      return await BrowserAutomationRunner(page: content).run([Self.step(.snapshot)])
    }
    #expect(result.lines.first?.hasPrefix("page: Fixture <data:text/html,") == true)
    #expect(result.lines.last?.hasPrefix("- button \"Go\" [ref=e") == true)
    #expect(!content.isHibernatable)
  }
}
