import ArgumentParser
import Foundation

struct BrowserCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "browser",
    abstract: "Drive a browser tab: read the page, click, type, and wait.",
    discussion: "Run `supacode browser guide` for the workflow.",
    subcommands: [
      Open.self,
      Navigate.self,
      Snapshot.self,
      Click.self,
      Fill.self,
      Select.self,
      Press.self,
      Wait.self,
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
    BrowserRequest.Target(tab: tab, worktree: worktree, quiet: quiet)
  }
}

nonisolated protocol BrowserStepCommand {
  var browser: BrowserTargetOptions { get }
  func step() -> [String: Any]
}

nonisolated enum BrowserRequest {
  struct Target {
    var tab: String?
    var worktree: String?
    var quiet = false
  }

  @discardableResult
  static func send(
    steps: [[String: Any]],
    target: Target,
    newTab: [String: Any]? = nil
  ) throws -> String? {
    var request: [String: Any] = ["steps": steps, "quiet": target.quiet]
    request["tabID"] = target.tab
    request["newTab"] = newTab
    let data = try JSONSerialization.data(withJSONObject: request)
    var params = ["request": String(bytes: data, encoding: .utf8) ?? "{}"]
    params["worktreeID"] = target.worktree
    let reply =
      try QueryDispatcher.query(resource: "browser", params: params, timeoutSeconds: CommandTimeout.defaultSeconds)
      .first ?? [:]
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
      var newTab: [String: Any] = ["background": backgroundOption.background]
      newTab["url"] = url
      let target = BrowserRequest.Target(worktree: worktree)
      guard let tabID = try BrowserRequest.send(steps: [], target: target, newTab: newTab) else {
        throw SocketClient.Error.responseError("Supacode did not report the new tab.")
      }
      print(tabID)
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
      try BrowserRequest.send(steps: [step()], target: browser.target)
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
      try BrowserRequest.send(steps: [step()], target: browser.target)
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
      try BrowserRequest.send(steps: [step()], target: browser.target)
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
      try BrowserRequest.send(steps: [step()], target: browser.target)
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
      try BrowserRequest.send(steps: [step()], target: browser.target)
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
      try BrowserRequest.send(steps: [step()], target: browser.target)
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
    }

    func step() -> [String: Any] {
      var step: [String: Any] = ["verb": "wait", "timeout": timeout, "hidden": hidden]
      step["target"] = target
      step["text"] = text
      step["url"] = url
      return step
    }

    func run() throws {
      try BrowserRequest.send(steps: [step()], target: browser.target)
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
      try BrowserRequest.send(steps: steps, target: browser.target)
    }
  }

  struct Guide: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print how to drive a browser tab.")

    func run() {
      print(BrowserGuide.text)
    }
  }
}
