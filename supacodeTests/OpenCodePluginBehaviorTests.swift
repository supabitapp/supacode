import Foundation
import JavaScriptCore
import Testing

@testable import SupacodeSettingsShared

/// Runs a generated OpenCode plugin in JavaScriptCore against a stubbed OpenCode
/// host, recording the presence event of every OSC the guarded command would emit.
private final class PluginRuntime {
  private static let host = """
    globalThis.setTimeout = () => 0
    globalThis.clearTimeout = () => {}
    const intervals = new Set()
    globalThis.setInterval = (tick) => intervals.add(tick) && tick
    globalThis.clearInterval = (tick) => intervals.delete(tick)
    const emitted = []
    const listeners = new Map()
    const parents = {}
    const running = new Set()
    const pending = { permission: {}, form: {} }
    const listed = (kind) => ({ list: (id) => pending[kind][id] })
    const hold = (kind, sessionID, id) => (pending[kind][sessionID] ??= []).push({ id, sessionID })
    const release = (kind, sessionID, id) => {
      pending[kind][sessionID] = (pending[kind][sessionID] ?? []).filter((prompt) => prompt.id !== id)
    }
    let route = { type: "home" }
    const record = (command) => {
      for (const match of command.matchAll(/3008;(?:start|end)=opencode;event=([a-z_]+)/g)) emitted.push(match[1])
    }
    const spawn = (shell, args) => {
      record(args[1])
      return { once: (event, done) => event === "exit" && done(), kill: () => {} }
    }
    const $ = (strings, ...values) => {
      record(values.join(" "))
      return { quiet: () => ({ nothrow: () => Promise.resolve() }) }
    }
    const host = {
      data: {
        on: (type, handler) => {
          listeners.set(type, handler)
          return () => listeners.delete(type)
        },
        session: {
          root: (id) => parents[id] ?? id,
          family: (root) => [root, ...Object.keys(parents).filter((id) => parents[id] === root)],
          status: (id) => (running.has(id) ? "running" : "idle"),
          permission: listed("permission"),
          form: listed("form"),
        },
      },
      ui: { router: { current: () => route } },
    }
    const dispatch = (type, data) => {
      if (type === "session.execution.started") running.add(data?.sessionID)
      else if (type.startsWith("session.execution.")) running.delete(data?.sessionID)
      else if (type === "permission.asked") hold("permission", data?.sessionID, data?.id)
      else if (type === "permission.replied") release("permission", data?.sessionID, data?.requestID)
      else if (type === "form.created") hold("form", data?.form?.sessionID, data?.form?.id)
      else if (type === "form.replied" || type === "form.cancelled") release("form", data?.sessionID, data?.id)
      listeners.get(type)?.({ type, data })
    }
    """

  private static let importLine = #"import { spawn } from "node:child_process""#

  private let context = JSContext()!
  private var exceptions: [String] = []

  init(module source: String) {
    context.exceptionHandler = { [unowned self] _, exception in
      exceptions.append(exception?.toString() ?? "unknown")
    }
    context.evaluateScript(Self.host)
    context.evaluateScript(
      source
        .replacing(Self.importLine, with: "")
        .replacing("export default", with: "globalThis.plugin ="))
  }

  nonisolated deinit {}

  static func importsSpawn(_ source: String) -> Bool {
    source.contains(importLine)
  }

  @discardableResult
  func evaluate(_ script: String) -> JSValue {
    context.evaluateScript(script)
  }

  func route(to sessionID: String) {
    evaluate(#"route = { type: "session", sessionID: "\#(sessionID)" }"#)
  }

  func setParent(of child: String, to parent: String) {
    evaluate(#"parents["\#(child)"] = "\#(parent)""#)
  }

  /// A session the service already runs when this TUI connects and hydrates.
  func markRunning(_ sessionID: String) {
    evaluate(#"running.add("\#(sessionID)")"#)
  }

  /// A question the session was already blocked on when this TUI hydrated.
  func markPendingQuestion(_ formID: String, in sessionID: String) {
    evaluate(#"hold("form", "\#(sessionID)", "\#(formID)")"#)
  }

  /// A permission the TUI's cache lists without this plugin having been asked for it.
  func markListedPermission(_ permissionID: String, in sessionID: String) {
    evaluate(#"hold("permission", "\#(sessionID)", "\#(permissionID)")"#)
  }

  func tick() {
    evaluate("intervals.forEach((tick) => tick())")
  }

  func send(_ type: String, _ data: String) {
    evaluate(#"dispatch("\#(type)", \#(data))"#)
  }

  /// Presence events emitted since the last call, then clears them.
  func drain() -> [String] {
    #expect(exceptions.isEmpty)
    return evaluate("emitted.splice(0)").toArray() as? [String] ?? []
  }
}

struct OpenCodeTUIPluginBehaviorTests {
  private func start() throws -> PluginRuntime {
    let source = OpenCodePluginContent.tuiSource()
    try #require(PluginRuntime.importsSpawn(source))
    let tui = PluginRuntime(module: source)
    tui.evaluate("plugin.setup(host).then((cleanup) => { globalThis.cleanup = cleanup })")
    #expect(tui.drain() == ["session_start"])
    return tui
  }

  @Test func cleanupEndsPresence() throws {
    let tui = try start()
    tui.evaluate("cleanup()")
    #expect(tui.drain() == ["session_end", "idle"])
  }

  @Test func routedTurnGoesBusyThenIdle() throws {
    let tui = try start()
    tui.route(to: "S")
    tui.send("session.execution.started", #"{ "sessionID": "S" }"#)
    tui.send("session.execution.succeeded", #"{ "sessionID": "S" }"#)
    #expect(tui.drain() == ["busy", "idle"])
  }

  @Test func ignoresSessionsThisTUIDoesNotShow() throws {
    let tui = try start()
    tui.route(to: "S")
    tui.send("session.execution.started", #"{ "sessionID": "other" }"#)
    tui.send("permission.asked", #"{ "id": "p", "sessionID": "other" }"#)
    tui.send("session.execution.succeeded", #"{ "sessionID": "other" }"#)
    #expect(tui.drain().isEmpty)
  }

  @Test func finishesAClaimedTurnAfterNavigatingAway() throws {
    let tui = try start()
    tui.route(to: "S")
    tui.send("session.execution.started", #"{ "sessionID": "S" }"#)
    tui.route(to: "elsewhere")
    tui.send("session.execution.succeeded", #"{ "sessionID": "S" }"#)
    #expect(tui.drain() == ["busy", "idle"])
  }

  @Test func subagentExecutionsKeepTheParentBusy() throws {
    let tui = try start()
    tui.setParent(of: "child", to: "S")
    tui.route(to: "S")
    tui.send("session.execution.started", #"{ "sessionID": "S" }"#)
    tui.send("session.execution.started", #"{ "sessionID": "child" }"#)
    tui.send("session.execution.succeeded", #"{ "sessionID": "child" }"#)
    #expect(tui.drain() == ["busy", "busy", "busy"])
    tui.send("session.execution.succeeded", #"{ "sessionID": "S" }"#)
    #expect(tui.drain() == ["idle"])
  }

  @Test func promptingASubagentDirectlyEndsIdle() throws {
    let tui = try start()
    tui.setParent(of: "child", to: "S")
    tui.route(to: "child")
    tui.send("session.execution.started", #"{ "sessionID": "child" }"#)
    tui.send("session.execution.succeeded", #"{ "sessionID": "child" }"#)
    #expect(tui.drain() == ["busy", "idle"])
  }

  @Test func permissionAndQuestionPromptsAwaitInput() throws {
    let tui = try start()
    tui.setParent(of: "child", to: "S")
    tui.route(to: "S")
    tui.send("session.execution.started", #"{ "sessionID": "S" }"#)
    tui.send("permission.asked", #"{ "id": "p", "sessionID": "S" }"#)
    tui.send("permission.replied", #"{ "requestID": "p", "sessionID": "S", "reply": "once" }"#)
    tui.send("form.created", #"{ "form": { "id": "f", "sessionID": "child" } }"#)
    tui.send("form.cancelled", #"{ "id": "f", "sessionID": "child" }"#)
    #expect(tui.drain() == ["busy", "awaiting_input", "busy", "awaiting_input", "busy"])
  }

  @Test func aPendingPromptOutlastsAnotherSessionFinishing() throws {
    let tui = try start()
    tui.route(to: "A")
    tui.send("session.execution.started", #"{ "sessionID": "A" }"#)
    tui.send("permission.asked", #"{ "id": "p", "sessionID": "A" }"#)
    tui.route(to: "B")
    tui.send("session.execution.started", #"{ "sessionID": "B" }"#)
    tui.send("session.execution.succeeded", #"{ "sessionID": "B" }"#)
    #expect(tui.drain() == ["busy", "awaiting_input", "awaiting_input", "awaiting_input"])
  }

  @Test func interruptingATurnEndsItsQuestion() throws {
    let tui = try start()
    tui.route(to: "S")
    tui.send("session.execution.started", #"{ "sessionID": "S" }"#)
    tui.send("form.created", #"{ "form": { "id": "f", "sessionID": "S" } }"#)
    tui.send("session.execution.interrupted", #"{ "sessionID": "S", "reason": "user" }"#)
    tui.send("form.cancelled", #"{ "id": "f", "sessionID": "S" }"#)
    tui.send("session.execution.started", #"{ "sessionID": "S" }"#)
    #expect(tui.drain() == ["busy", "awaiting_input", "idle", "busy"])
  }

  @Test func failedTurnReportsErrorUntilTheNextTurn() throws {
    let tui = try start()
    tui.route(to: "S")
    tui.send("session.execution.started", #"{ "sessionID": "S" }"#)
    tui.send("session.execution.failed", #"{ "sessionID": "S" }"#)
    tui.send("session.execution.started", #"{ "sessionID": "S" }"#)
    #expect(tui.drain() == ["busy", "error", "busy"])
  }

  @Test func aFailureSurvivesAnotherSessionFinishing() throws {
    let tui = try start()
    tui.route(to: "A")
    tui.send("session.execution.started", #"{ "sessionID": "A" }"#)
    tui.route(to: "B")
    tui.send("session.execution.started", #"{ "sessionID": "B" }"#)
    tui.send("session.execution.failed", #"{ "sessionID": "A" }"#)
    tui.send("session.execution.succeeded", #"{ "sessionID": "B" }"#)
    #expect(tui.drain() == ["busy", "busy", "busy", "error"])
  }

  @Test func aBackgroundSubagentOutlivesItsParent() throws {
    let tui = try start()
    tui.setParent(of: "child", to: "S")
    tui.route(to: "S")
    tui.send("session.execution.started", #"{ "sessionID": "S" }"#)
    tui.send("session.execution.started", #"{ "sessionID": "child" }"#)
    tui.route(to: "elsewhere")
    tui.send("session.execution.succeeded", #"{ "sessionID": "S" }"#)
    tui.send("permission.asked", #"{ "id": "p", "sessionID": "child" }"#)
    tui.send("permission.replied", #"{ "requestID": "p", "sessionID": "child", "reply": "once" }"#)
    tui.send("session.execution.succeeded", #"{ "sessionID": "child" }"#)
    #expect(tui.drain() == ["busy", "busy", "busy", "awaiting_input", "busy", "idle"])
  }

  @Test func adoptsATurnThatStartedBeforeThisTUIOpenedIt() throws {
    let tui = try start()
    tui.markRunning("S")
    tui.route(to: "S")
    tui.tick()
    tui.tick()
    tui.send("session.execution.succeeded", #"{ "sessionID": "S" }"#)
    tui.tick()
    #expect(tui.drain() == ["busy", "idle"])
  }

  @Test func adoptsAQuestionThatWasPendingBeforeThisTUIOpenedIt() throws {
    let tui = try start()
    tui.markRunning("S")
    tui.markPendingQuestion("f", in: "S")
    tui.route(to: "S")
    tui.tick()
    tui.send("form.replied", #"{ "id": "f", "sessionID": "S" }"#)
    tui.tick()
    tui.send("session.execution.succeeded", #"{ "sessionID": "S" }"#)
    #expect(tui.drain() == ["awaiting_input", "busy", "idle"])
  }

  @Test func adoptsASubagentBlockedOnAQuestionWhenRejoiningItsParent() throws {
    let tui = try start()
    tui.setParent(of: "child", to: "S")
    tui.markRunning("S")
    tui.markRunning("child")
    tui.markPendingQuestion("f", in: "child")
    tui.route(to: "S")
    tui.tick()
    tui.send("form.replied", #"{ "id": "f", "sessionID": "child" }"#)
    #expect(tui.drain() == ["awaiting_input", "busy"])
  }

  @Test func anAdoptedBackgroundSubagentOutlivesItsParent() throws {
    let tui = try start()
    tui.setParent(of: "child", to: "S")
    tui.markRunning("S")
    tui.markRunning("child")
    tui.route(to: "S")
    tui.tick()
    tui.send("session.execution.succeeded", #"{ "sessionID": "S" }"#)
    tui.send("session.execution.succeeded", #"{ "sessionID": "child" }"#)
    #expect(tui.drain() == ["busy", "busy", "idle"])
  }

  @Test func adoptingABlockedFamilyClearsAnEarlierError() throws {
    let tui = try start()
    tui.route(to: "A")
    tui.send("session.execution.started", #"{ "sessionID": "A" }"#)
    tui.send("session.execution.failed", #"{ "sessionID": "A" }"#)
    tui.setParent(of: "child", to: "S")
    tui.markRunning("S")
    tui.markRunning("child")
    tui.markPendingQuestion("f", in: "child")
    tui.route(to: "S")
    tui.tick()
    #expect(tui.drain() == ["busy", "error", "busy", "awaiting_input"])
  }

  @Test func aListedPermissionItWasNotAskedForDoesNotAwaitInput() throws {
    let tui = try start()
    tui.route(to: "S")
    tui.send("session.execution.started", #"{ "sessionID": "S" }"#)
    tui.markListedPermission("p", in: "S")
    tui.tick()
    #expect(tui.drain() == ["busy"])
  }

  @Test func doesNotAdoptSessionsThisTUIIsNotShowing() throws {
    let tui = try start()
    tui.markRunning("other")
    tui.tick()
    tui.route(to: "S")
    tui.tick()
    #expect(tui.drain().isEmpty)
  }

  @Test func cleanupStopsAdoptingRunningSessions() throws {
    let tui = try start()
    tui.evaluate("cleanup()")
    tui.markRunning("S")
    tui.route(to: "S")
    tui.tick()
    #expect(tui.drain() == ["session_end", "idle"])
  }

  @Test func malformedPayloadsAreIgnoredWithoutThrowing() throws {
    let tui = try start()
    tui.route(to: "S")
    tui.send("session.execution.started", #"{ "sessionID": "S" }"#)
    tui.send("form.created", "{}")
    tui.send("permission.asked", "undefined")
    #expect(tui.drain() == ["busy"])
  }
}

struct OpenCodeServerPluginBehaviorTests {
  @Test func setupIsInertForOpenCode2() {
    let server = PluginRuntime(module: OpenCodePluginContent.serverSource())
    #expect(server.evaluate("plugin.id").toString() == "supacode.presence")
    #expect(server.evaluate("plugin.setup()").isUndefined)
    #expect(server.drain().isEmpty)
  }

  @Test func serverHooksReportPresenceForOpenCode1() {
    let server = PluginRuntime(module: OpenCodePluginContent.serverSource())
    server.evaluate("plugin.server({ $ }).then((hooks) => { globalThis.hooks = hooks })")
    #expect(server.drain() == ["session_start"])
    server.evaluate(
      """
      hooks["tool.execute.before"]()
      hooks["tool.execute.after"]()
      hooks["permission.ask"]()
      hooks.event({ event: { type: "permission.replied" } })
      hooks.event({ event: { type: "session.idle" } })
      hooks.dispose()
      """)
    #expect(server.drain() == ["busy", "idle", "awaiting_input", "busy", "idle", "session_end", "idle"])
  }
}
