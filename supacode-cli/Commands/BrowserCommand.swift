import ArgumentParser
import Foundation

struct BrowserCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "browser",
    abstract: "Drive a browser tab: read the page, click, type, and wait.",
    discussion: "Run `supacode browser guide` for the workflow.",
    subcommands: [
      Open.self,
      Tabs.self,
      Close.self,
      Navigate.self,
      Snapshot.self,
      Click.self,
      Fill.self,
      Select.self,
      Press.self,
      Wait.self,
      Eval.self,
      Screenshot.self,
      Console.self,
      Dialog.self,
      Batch.self,
      Guide.self,
    ]
  )
}

struct BrowserTargetOptions: ParsableArguments {
  @Option(
    name: [.short, .long],
    help: "Browser tab ID, as printed by `browser open`. Defaults to the worktree's only browser tab.")
  var tab: String?

  @Option(name: [.short, .long], help: "Worktree ID, used when no tab is given. Defaults to the focused worktree.")
  var worktree: String?

  @Flag(name: [.short, .long], help: "Print only the acknowledgement, not what changed on the page.")
  var quiet = false

  var target: BrowserRequest.Target {
    BrowserRequest.Target(tab: tab, worktree: worktree)
  }
}

nonisolated protocol BrowserStepCommand {
  var browser: BrowserTargetOptions { get }
  func step() -> [String: Any]
}

nonisolated enum BrowserRequest {
  static let baseTimeoutSeconds = 60.0
  static let stepTimeoutSeconds = 45.0

  struct Target {
    var tab: String?
    var worktree: String?
  }

  static func run(steps: [[String: Any]], target: Target, quiet: Bool) throws {
    let stepBudgets = steps.map { $0["timeout"] as? Double ?? stepTimeoutSeconds }
    try send(
      ["operation": "run", "steps": steps, "quiet": quiet],
      target: target,
      timeoutSeconds: stepBudgets.reduce(baseTimeoutSeconds, +)
    )
  }

  @discardableResult
  static func send(
    _ operation: [String: Any],
    target: Target,
    timeoutSeconds: Double = baseTimeoutSeconds + stepTimeoutSeconds
  ) throws -> String? {
    var request = operation
    request["tabID"] = target.tab
    let data = try JSONSerialization.data(withJSONObject: request)
    var params = ["request": String(bytes: data, encoding: .utf8) ?? "{}"]
    params["worktreeID"] = target.worktree
    let reply =
      try QueryDispatcher.query(
        resource: "browser",
        params: params,
        timeoutSeconds: Int(timeoutSeconds.rounded(.up))
      ).first ?? [:]
    if let output = reply["output"] {
      print(output)
    }
    if let error = reply["error"] {
      throw SocketClient.Error.responseError(error)
    }
    return reply["id"]
  }
}

extension BrowserCommand {
  struct Open: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Open a new browser tab beside the terminal and print its tab ID.")

    @Argument(help: "URL to load. Omit for a blank tab.")
    var url: String?

    @Option(name: [.short, .long], help: "Worktree ID. Defaults to the focused worktree.")
    var worktree: String?

    @OptionGroup var backgroundOption: BackgroundOption

    func run() throws {
      var operation: [String: Any] = ["operation": "open", "background": backgroundOption.background]
      operation["url"] = url
      guard let tabID = try BrowserRequest.send(operation, target: BrowserRequest.Target(worktree: worktree)) else {
        throw SocketClient.Error.responseError("Supacode did not report the new tab.")
      }
      print(tabID)
    }
  }

  struct Tabs: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "List the worktree's browser tabs: ID, title, and address.")

    @Option(name: [.short, .long], help: "Worktree ID. Defaults to the focused worktree.")
    var worktree: String?

    func run() throws {
      try BrowserRequest.send(["operation": "tabs"], target: BrowserRequest.Target(worktree: worktree))
    }
  }

  struct Close: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Close a browser tab.")

    @Option(
      name: [.short, .long],
      help: "Browser tab ID. Defaults to the worktree's only browser tab.")
    var tab: String?

    @Option(name: [.short, .long], help: "Worktree ID, used when no tab is given. Defaults to the focused worktree.")
    var worktree: String?

    func run() throws {
      try BrowserRequest.send(["operation": "close"], target: BrowserRequest.Target(tab: tab, worktree: worktree))
    }
  }

  struct Navigate: ParsableCommand, BrowserStepCommand {
    static let configuration = CommandConfiguration(abstract: "Load a URL in the tab.")

    @Argument(help: "URL to load.")
    var url: String

    @OptionGroup var browser: BrowserTargetOptions

    func step() -> [String: Any] {
      ["verb": "navigate", "url": url]
    }

    func run() throws {
      try BrowserRequest.run(steps: [step()], target: browser.target, quiet: browser.quiet)
    }
  }

  struct Snapshot: ParsableCommand, BrowserStepCommand {
    static let configuration = CommandConfiguration(
      abstract: "Print the page's interactive elements, each with a ref such as e12.")

    @Flag(name: .long, help: "Print the whole page, including text content.")
    var full = false

    @Option(name: .long, help: "Print only the part of the page under this ref.")
    var scope: String?

    @OptionGroup var browser: BrowserTargetOptions

    func step() -> [String: Any] {
      var step: [String: Any] = ["verb": "snapshot", "full": full]
      step["scope"] = scope
      return step
    }

    func run() throws {
      try BrowserRequest.run(steps: [step()], target: browser.target, quiet: browser.quiet)
    }
  }

  struct Click: ParsableCommand, BrowserStepCommand {
    static let configuration = CommandConfiguration(abstract: "Click an element.")

    @Argument(help: "Ref from a snapshot, or a locator such as 'role=button[name=\"Save\"]' or 'text=Sign in'.")
    var target: String

    @OptionGroup var browser: BrowserTargetOptions

    func step() -> [String: Any] {
      ["verb": "click", "target": target]
    }

    func run() throws {
      try BrowserRequest.run(steps: [step()], target: browser.target, quiet: browser.quiet)
    }
  }

  struct Fill: ParsableCommand, BrowserStepCommand {
    static let configuration = CommandConfiguration(abstract: "Replace the text of a field.")

    @Argument(help: "Ref or locator of the field.")
    var target: String

    @Argument(help: "Text to put in the field. An empty string clears it.")
    var text: String

    @OptionGroup var browser: BrowserTargetOptions

    func step() -> [String: Any] {
      ["verb": "fill", "target": target, "text": text]
    }

    func run() throws {
      try BrowserRequest.run(steps: [step()], target: browser.target, quiet: browser.quiet)
    }
  }

  struct Select: ParsableCommand, BrowserStepCommand {
    static let configuration = CommandConfiguration(abstract: "Choose an option of a select.")

    @Argument(help: "Ref or locator of the select.")
    var target: String

    @Argument(help: "Option label or value.")
    var option: String

    @OptionGroup var browser: BrowserTargetOptions

    func step() -> [String: Any] {
      ["verb": "select", "target": target, "option": option]
    }

    func run() throws {
      try BrowserRequest.run(steps: [step()], target: browser.target, quiet: browser.quiet)
    }
  }

  struct Press: ParsableCommand, BrowserStepCommand {
    static let configuration = CommandConfiguration(
      abstract: "Press a key, such as Enter, Tab, Escape, ArrowDown, a, or Meta+a.")

    @Argument(help: "Key to press.")
    var key: String

    @Argument(help: "Ref or locator to focus first. Defaults to the focused element.")
    var target: String?

    @OptionGroup var browser: BrowserTargetOptions

    func step() -> [String: Any] {
      var step: [String: Any] = ["verb": "press", "key": key]
      step["target"] = target
      return step
    }

    func run() throws {
      try BrowserRequest.run(steps: [step()], target: browser.target, quiet: browser.quiet)
    }
  }

  struct Wait: ParsableCommand, BrowserStepCommand {
    static let configuration = CommandConfiguration(
      abstract: "Wait for an element, for text, or for a URL.")

    @Argument(help: "Ref or locator that must become visible.")
    var target: String?

    @Option(name: .long, help: "Text that must appear on the page.")
    var text: String?

    @Option(name: .long, help: "URL the tab must reach. `*` matches any run of characters.")
    var url: String?

    @Flag(name: .long, help: "Wait for the target to disappear instead.")
    var hidden = false

    @Option(name: .long, help: "Seconds to wait before failing.")
    var timeout: Double = 10

    @OptionGroup var browser: BrowserTargetOptions

    func validate() throws {
      guard [target, text, url].compactMap(\.self).count == 1 else {
        throw ValidationError("Pass exactly one of a target, --text, or --url.")
      }
      if hidden, target == nil {
        throw ValidationError("--hidden needs a target.")
      }
      guard (0...600).contains(timeout) else {
        throw ValidationError("--timeout must be between 0 and 600 seconds.")
      }
    }

    func step() -> [String: Any] {
      var step: [String: Any] = ["verb": "wait", "timeout": timeout, "hidden": hidden]
      step["target"] = target
      step["text"] = text
      step["url"] = url
      return step
    }

    func run() throws {
      try BrowserRequest.run(steps: [step()], target: browser.target, quiet: browser.quiet)
    }
  }

  struct Eval: ParsableCommand, BrowserStepCommand {
    static let configuration = CommandConfiguration(
      abstract: "Run JavaScript in the page and print the result as JSON.",
      discussion: "Pass an expression such as 'document.title', or statements that end in a return.")

    @Argument(help: "JavaScript to run. `await` is allowed.")
    var source: String

    @OptionGroup var browser: BrowserTargetOptions

    func step() -> [String: Any] {
      ["verb": "eval", "source": source]
    }

    func run() throws {
      try BrowserRequest.run(steps: [step()], target: browser.target, quiet: browser.quiet)
    }
  }

  struct Screenshot: ParsableCommand, BrowserStepCommand {
    static let configuration = CommandConfiguration(
      abstract: "Save a PNG of the visible page and print its path.")

    @Argument(help: "Where to save the PNG. Defaults to a new file in the temporary directory.")
    var path: String?

    @OptionGroup var browser: BrowserTargetOptions

    func step() -> [String: Any] {
      var step: [String: Any] = ["verb": "screenshot"]
      step["path"] = path.map { URL(fileURLWithPath: $0).standardizedFileURL.path(percentEncoded: false) }
      return step
    }

    func run() throws {
      try BrowserRequest.run(steps: [step()], target: browser.target, quiet: browser.quiet)
    }
  }

  struct Console: ParsableCommand, BrowserStepCommand {
    static let configuration = CommandConfiguration(
      abstract: "Print the page's console messages and uncaught errors.",
      discussion: "Messages are kept from the first browser command sent to the tab.")

    @Flag(name: .long, help: "Forget the messages after printing them.")
    var clear = false

    @OptionGroup var browser: BrowserTargetOptions

    func step() -> [String: Any] {
      ["verb": "console", "clear": clear]
    }

    func run() throws {
      try BrowserRequest.run(steps: [step()], target: browser.target, quiet: browser.quiet)
    }
  }

  struct Dialog: ParsableCommand, BrowserStepCommand {
    enum Answer: String, ExpressibleByArgument, CaseIterable {
      case accept
      case dismiss
    }

    static let configuration = CommandConfiguration(
      abstract: "Answer the alert, confirm, or prompt the page is showing.")

    @Argument(help: "accept or dismiss.")
    var answer: Answer

    @Option(name: .long, help: "Text to enter in a prompt before accepting it.")
    var text: String?

    @OptionGroup var browser: BrowserTargetOptions

    func step() -> [String: Any] {
      var step: [String: Any] = ["verb": "dialog", "accept": answer == .accept]
      step["text"] = text
      return step
    }

    func run() throws {
      try BrowserRequest.run(steps: [step()], target: browser.target, quiet: browser.quiet)
    }
  }

  struct Batch: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Run steps from stdin, one per line, and stop at the first failure.",
      discussion: "Each line is a browser command without `supacode browser`, such as `fill e5 \"ada@example.com\"`.")

    @OptionGroup var browser: BrowserTargetOptions

    func run() throws {
      var steps: [[String: Any]] = []
      var lineNumber = 0
      while let line = readLine() {
        lineNumber += 1
        let tokens: [String]
        do {
          tokens = try BrowserBatchLine.tokens(line)
        } catch {
          throw ValidationError("Line \(lineNumber): \(error.localizedDescription)")
        }
        guard !tokens.isEmpty else { continue }
        let parsed: any ParsableCommand
        do {
          parsed = try BrowserCommand.parseAsRoot(tokens)
        } catch {
          throw ValidationError("Line \(lineNumber): \(BrowserCommand.message(for: error))")
        }
        guard let command = parsed as? any BrowserStepCommand else {
          throw ValidationError("Line \(lineNumber): `\(tokens[0])` cannot run in a batch.")
        }
        guard command.browser.tab == nil, command.browser.worktree == nil else {
          throw ValidationError("Line \(lineNumber): pass -t and -w to `batch`, not to a step.")
        }
        steps.append(command.step())
      }
      guard !steps.isEmpty else {
        throw ValidationError("No steps on stdin.")
      }
      try BrowserRequest.run(steps: steps, target: browser.target, quiet: browser.quiet)
    }
  }

  struct Guide: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print how to drive a browser tab.")

    func run() {
      print(BrowserGuide.text)
    }
  }
}
