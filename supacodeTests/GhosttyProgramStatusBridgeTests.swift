import Foundation
import GhosttyKit
import Testing

@testable import supacode

@MainActor
struct GhosttyProgramStatusBridgeTests {
  private func deliver(
    state: ghostty_action_program_status_state_e,
    kind: ghostty_action_program_status_kind_e = GHOSTTY_ACTION_PROGRAM_STATUS_KIND_NONE,
    progress: Int8 = -1,
    id: String = "",
    app: String = "",
    title: String = "",
    msg: String = "",
    to bridge: GhosttySurfaceBridge
  ) -> Bool {
    var action = ghostty_action_s()
    action.tag = GHOSTTY_ACTION_PROGRAM_STATUS
    return id.withCString { idPtr in
      app.withCString { appPtr in
        title.withCString { titlePtr in
          msg.withCString { msgPtr in
            action.action.program_status = ghostty_action_program_status_s(
              state: state,
              kind: kind,
              progress: progress,
              id: idPtr,
              app: appPtr,
              title: titlePtr,
              msg: msgPtr
            )
            return bridge.handleAction(target: ghostty_target_s(), action: action)
          }
        }
      }
    }
  }

  @Test func fullReportReachesTheCallback() {
    let bridge = GhosttySurfaceBridge()
    var received: [ProgramStatusReport] = []
    bridge.onProgramStatus = { received.append($0) }

    let handled = deliver(
      state: GHOSTTY_ACTION_PROGRAM_STATUS_STATE_BLOCKED,
      kind: GHOSTTY_ACTION_PROGRAM_STATUS_KIND_PERMISSION,
      progress: 40,
      id: "deploy/us-east",
      app: "claude-code",
      title: "Deploy",
      msg: "Approve the write?",
      to: bridge
    )

    #expect(handled == false)
    #expect(
      received == [
        ProgramStatusReport(
          state: .blocked,
          id: "deploy/us-east",
          kind: .permission,
          progress: 40,
          app: "claude-code",
          title: "Deploy",
          message: "Approve the write?"
        )
      ]
    )
  }

  @Test func emptyStringsAndNegativeProgressReadAsAbsent() {
    let bridge = GhosttySurfaceBridge()
    var received: ProgramStatusReport?
    bridge.onProgramStatus = { received = $0 }

    _ = deliver(state: GHOSTTY_ACTION_PROGRAM_STATUS_STATE_IDLE, to: bridge)

    #expect(received == ProgramStatusReport(state: .idle))
    #expect(received?.isRoot == true)
  }

  @Test(arguments: [
    (GHOSTTY_ACTION_PROGRAM_STATUS_STATE_IDLE, ProgramStatusReport.State.idle),
    (GHOSTTY_ACTION_PROGRAM_STATUS_STATE_WORKING, .working),
    (GHOSTTY_ACTION_PROGRAM_STATUS_STATE_DONE, .done),
    (GHOSTTY_ACTION_PROGRAM_STATUS_STATE_BLOCKED, .blocked),
    (GHOSTTY_ACTION_PROGRAM_STATUS_STATE_ERROR, .error),
    (GHOSTTY_ACTION_PROGRAM_STATUS_STATE_CLEAR, .clear),
  ])
  func everyStateMaps(_ state: ghostty_action_program_status_state_e, _ expected: ProgramStatusReport.State) {
    #expect(ProgramStatusReport.State(state) == expected)
  }

  @Test(arguments: [
    (GHOSTTY_ACTION_PROGRAM_STATUS_KIND_NONE, ProgramStatusReport.Kind?.none),
    (GHOSTTY_ACTION_PROGRAM_STATUS_KIND_PERMISSION, .permission),
    (GHOSTTY_ACTION_PROGRAM_STATUS_KIND_QUESTION, .question),
    (GHOSTTY_ACTION_PROGRAM_STATUS_KIND_AUTH, .auth),
  ])
  func everyKindMaps(_ kind: ghostty_action_program_status_kind_e, _ expected: ProgramStatusReport.Kind?) {
    #expect(ProgramStatusReport.Kind(kind) == expected)
  }

  @Test func unknownStateFromANewerLibghosttyIsDropped() {
    let bridge = GhosttySurfaceBridge()
    var received = false
    bridge.onProgramStatus = { _ in received = true }

    let handled = deliver(state: ghostty_action_program_status_state_e(rawValue: 99), to: bridge)

    #expect(handled == false)
    #expect(received == false)
  }

  @Test func otherActionsNeverReachTheCallback() {
    let bridge = GhosttySurfaceBridge()
    var received = false
    bridge.onProgramStatus = { _ in received = true }

    var action = ghostty_action_s()
    action.tag = GHOSTTY_ACTION_RING_BELL
    _ = bridge.handleAction(target: ghostty_target_s(), action: action)

    #expect(received == false)
  }

  @Test func reportedProgressPassesThrough() {
    let bridge = GhosttySurfaceBridge()
    var received: ProgramStatusReport?
    bridge.onProgramStatus = { received = $0 }

    _ = deliver(state: GHOSTTY_ACTION_PROGRAM_STATUS_STATE_WORKING, progress: 0, app: "codex", to: bridge)
    #expect(received?.progress == 0)

    _ = deliver(state: GHOSTTY_ACTION_PROGRAM_STATUS_STATE_WORKING, progress: 100, app: "codex", to: bridge)
    #expect(received?.progress == 100)
  }
}
