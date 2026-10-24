import AppKit
import Foundation
import GhosttyKit
import Testing

@testable import supacode

@MainActor
struct ProgramStatusBridgeTests {
  private func deliver(
    event: ghostty_action_program_status_event_e = GHOSTTY_PROGRAM_STATUS_EVENT_REPORT,
    state: ghostty_action_program_status_state_e = GHOSTTY_PROGRAM_STATUS_STATE_IDLE,
    kind: ghostty_action_program_status_kind_e = GHOSTTY_PROGRAM_STATUS_KIND_NONE,
    progress: Int8 = -1,
    id: String = "",
    app: String = "",
    title: String = "",
    message: String = ""
  ) -> [ProgramStatusEvent] {
    let bridge = GhosttySurfaceBridge()
    var received: [ProgramStatusEvent] = []
    bridge.onProgramStatus = { received.append($0) }
    id.withCString { id in
      app.withCString { app in
        title.withCString { title in
          message.withCString { message in
            let value = ghostty_action_program_status_s(
              event: event,
              state: state,
              kind: kind,
              progress: progress,
              id: id,
              app: app,
              title: title,
              message: message
            )
            withUnsafePointer(to: value) { pointer in
              var action = ghostty_action_s()
              action.tag = GHOSTTY_ACTION_PROGRAM_STATUS
              action.action.program_status = pointer
              _ = bridge.handleAction(target: ghostty_target_s(), action: action)
            }
          }
        }
      }
    }
    return received
  }

  @Test func aReportCopiesEveryField() {
    let events = deliver(
      state: GHOSTTY_PROGRAM_STATUS_STATE_BLOCKED,
      kind: GHOSTTY_PROGRAM_STATUS_KIND_PERMISSION,
      progress: 42,
      id: "tf/plan",
      app: "terraform",
      title: "Plan",
      message: "Apply 3 to add?"
    )

    #expect(
      events == [
        .report(
          ProgramStatusReport(
            id: "tf/plan",
            state: .blocked,
            kind: .permission,
            progress: 42,
            app: "terraform",
            title: "Plan",
            message: "Apply 3 to add?"
          ))
      ])
  }

  @Test func emptyStringsAndNoProgressReadAsAbsent() {
    let events = deliver(state: GHOSTTY_PROGRAM_STATUS_STATE_WORKING, kind: GHOSTTY_PROGRAM_STATUS_KIND_AUTH)

    #expect(events == [.report(ProgramStatusReport(id: "", state: .working))])
  }

  @Test func aClearReportBecomesAClearOfItsID() {
    let events = deliver(state: GHOSTTY_PROGRAM_STATUS_STATE_CLEAR, id: "deploy")

    #expect(events == [.clear(id: "deploy")])
  }

  @Test func shellMarksBecomeBoundaryEvents() {
    #expect(deliver(event: GHOSTTY_PROGRAM_STATUS_EVENT_PROMPT_START) == [.promptStart])
    #expect(deliver(event: GHOSTTY_PROGRAM_STATUS_EVENT_COMMAND_START) == [.commandStart])
    #expect(deliver(event: GHOSTTY_PROGRAM_STATUS_EVENT_COMMAND_END) == [.commandEnd])
  }

  @Test func aNullReportIsDropped() {
    let bridge = GhosttySurfaceBridge()
    var invoked = false
    bridge.onProgramStatus = { _ in invoked = true }
    var action = ghostty_action_s()
    action.tag = GHOSTTY_ACTION_PROGRAM_STATUS
    action.action.program_status = nil

    _ = bridge.handleAction(target: ghostty_target_s(), action: action)

    #expect(!invoked)
  }
}

/// Runs real programs in a real Ghostty surface, so the parser, the support
/// query reply and the action all go through the patched GhosttyKit.
@MainActor
@Suite(.serialized)
struct ProgramStatusSurfaceTests {
  /// Asks for support, then reports whether the reply came back (dd gives up
  /// after 3 s without one).
  private static let queryScript = #"""
    stty -echo -icanon min 0 time 30
    printf "\033]7501;?\007"
    reply=$(dd bs=1 count=9 2>/dev/null)
    case "$reply" in
      *7501*) printf "\033]7501;state=done:app=answered\007" ;;
      *) printf "\033]7501;state=done:app=unanswered\007" ;;
    esac
    sleep 30
    """#

  private static let lifecycleScript = #"""
    printf "\033]7501;state=blocked:kind=permission:progress=50:id=job:app=e2e:msg=YXBwcm92ZQ\007"
    printf "\033]133;C\007\033]133;D;0\007\033]133;A\007"
    printf "\033c"
    sleep 30
    """#

  private func events(
    from script: String,
    runtime: GhosttyRuntime,
    until isLast: @escaping (ProgramStatusEvent) -> Bool
  ) async throws -> [ProgramStatusEvent] {
    let (stream, continuation) = AsyncStream.makeStream(of: ProgramStatusEvent.self)
    let view = GhosttySurfaceView(
      id: UUID(),
      runtime: runtime,
      workingDirectory: nil,
      command: "/bin/sh -c '\(script)'",
      disableShellIntegration: true,
      initialGeometry: .fallback,
      context: GHOSTTY_SURFACE_CONTEXT_TAB
    )
    defer { view.closeSurface() }
    try #require(view.surface != nil, "Ghostty could not create a surface here")
    view.bridge.onProgramStatus = { event in
      continuation.yield(event)
      if isLast(event) { continuation.finish() }
    }
    var received: [ProgramStatusEvent] = []
    for await event in stream {
      received.append(event)
    }
    return received
  }

  private static func isReport(_ event: ProgramStatusEvent) -> Bool {
    if case .report = event { return true }
    return false
  }

  @Test(.timeLimit(.minutes(1)))
  func reportsAndShellMarksArriveInStreamOrder() async throws {
    let received = try await events(from: Self.lifecycleScript, runtime: GhosttyRuntime()) {
      $0 == .clear(id: "")
    }

    #expect(
      received == [
        .report(
          ProgramStatusReport(
            id: "job", state: .blocked, kind: .permission, progress: 50, app: "e2e", message: "approve")),
        .commandStart,
        .commandEnd,
        .promptStart,
        .clear(id: ""),
      ])
  }

  @Test(.timeLimit(.minutes(1)))
  func theSupportQueryGoesUnansweredWhenDisabled() async throws {
    let runtime = GhosttyRuntime(configOverrides: "program-status = false")
    let received = try await events(from: Self.queryScript, runtime: runtime, until: Self.isReport)

    #expect(received == [.report(ProgramStatusReport(id: "", state: .done, app: "unanswered"))])
  }

  @Test(.timeLimit(.minutes(1)))
  func theSupportQueryIsAnsweredWhenEnabled() async throws {
    let runtime = GhosttyRuntime(configOverrides: "program-status = true")
    let received = try await events(from: Self.queryScript, runtime: runtime, until: Self.isReport)

    #expect(received == [.report(ProgramStatusReport(id: "", state: .done, app: "answered"))])
  }
}
