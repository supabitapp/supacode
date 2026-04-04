import Darwin
import Foundation
import Testing

@testable import supacode

@MainActor
struct AgentHookSocketServerTests {
  // MARK: - Busy message parsing.

  @Test func parsesValidBusyActiveMessage() {
    let worktreeID = "/tmp/repo/wt-1"
    let tabID = UUID()
    let surfaceID = UUID()
    let raw = "\(worktreeID) \(tabID.uuidString) \(surfaceID.uuidString) 1"
    let message = AgentHookSocketServer.parse(data: Data(raw.utf8))

    guard case .busy(let wID, let tID, let sID, let active) = message else {
      Issue.record("Expected busy message, got \(String(describing: message))")
      return
    }
    #expect(wID == worktreeID)
    #expect(tID == tabID)
    #expect(sID == surfaceID)
    #expect(active == true)
  }

  @Test func parsesValidBusyInactiveMessage() {
    let tabID = UUID()
    let surfaceID = UUID()
    let raw = "wt \(tabID.uuidString) \(surfaceID.uuidString) 0"
    let message = AgentHookSocketServer.parse(data: Data(raw.utf8))

    guard case .busy(_, _, _, let active) = message else {
      Issue.record("Expected busy message")
      return
    }
    #expect(active == false)
  }

  @Test func nonZeroBusyFlagTreatedAsActive() {
    let tabID = UUID()
    let surfaceID = UUID()
    let raw = "wt \(tabID.uuidString) \(surfaceID.uuidString) anything"
    let message = AgentHookSocketServer.parse(data: Data(raw.utf8))

    guard case .busy(_, _, _, let active) = message else {
      Issue.record("Expected busy message")
      return
    }
    #expect(active == true)
  }

  // MARK: - Notification message parsing.

  @Test func parsesValidNotificationWithPayload() {
    let tabID = UUID()
    let surfaceID = UUID()
    let payload = #"{"hook_event_name":"Stop","title":"Done","message":"All tasks complete"}"#
    let raw = "wt \(tabID.uuidString) \(surfaceID.uuidString) claude\n\(payload)"
    let message = AgentHookSocketServer.parse(data: Data(raw.utf8))

    guard case .notification(_, let tID, let sID, let notification) = message else {
      Issue.record("Expected notification message, got \(String(describing: message))")
      return
    }
    #expect(tID == tabID)
    #expect(sID == surfaceID)
    #expect(notification.agent == "claude")
    #expect(notification.event == "Stop")
    #expect(notification.title == "Done")
    #expect(notification.body == "All tasks complete")
  }

  @Test func parsesNotificationWithLastAssistantMessageFallback() {
    let tabID = UUID()
    let surfaceID = UUID()
    let payload = #"{"hook_event_name":"Stop","last_assistant_message":"fallback body"}"#
    let raw = "wt \(tabID.uuidString) \(surfaceID.uuidString) codex\n\(payload)"
    let message = AgentHookSocketServer.parse(data: Data(raw.utf8))

    guard case .notification(_, _, _, let notification) = message else {
      Issue.record("Expected notification message")
      return
    }
    #expect(notification.agent == "codex")
    #expect(notification.body == "fallback body")
  }

  @Test func invalidJSONPayloadDropsNotification() {
    let tabID = UUID()
    let surfaceID = UUID()
    let raw = "wt \(tabID.uuidString) \(surfaceID.uuidString) claude\nnot json at all"
    let message = AgentHookSocketServer.parse(data: Data(raw.utf8))

    #expect(message == nil)
  }

  // MARK: - Malformed messages.

  @Test func malformedHeaderWithFewerThanThreeFieldsReturnsNil() {
    let message = AgentHookSocketServer.parse(data: Data("wt only-two-fields".utf8))
    #expect(message == nil)
  }

  @Test func invalidTabIDReturnsNil() {
    let surfaceID = UUID()
    let raw = "wt not-a-uuid \(surfaceID.uuidString) 1"
    let message = AgentHookSocketServer.parse(data: Data(raw.utf8))
    #expect(message == nil)
  }

  @Test func invalidSurfaceIDReturnsNil() {
    let tabID = UUID()
    let raw = "wt \(tabID.uuidString) not-a-uuid 1"
    let message = AgentHookSocketServer.parse(data: Data(raw.utf8))
    #expect(message == nil)
  }

  @Test func emptyInputReturnsNil() {
    let message = AgentHookSocketServer.parse(data: Data())
    #expect(message == nil)
  }

  @Test func whitespaceOnlyInputReturnsNil() {
    let message = AgentHookSocketServer.parse(data: Data("   \n  \n  ".utf8))
    #expect(message == nil)
  }

  // MARK: - Agent name defaults.

  @Test func missingAgentNameDefaultsToUnknown() {
    let tabID = UUID()
    let surfaceID = UUID()
    // Only 3 header fields + a second line → notification with no agent.
    let raw = "wt \(tabID.uuidString) \(surfaceID.uuidString)\n{\"hook_event_name\":\"Stop\"}"
    let message = AgentHookSocketServer.parse(data: Data(raw.utf8))

    guard case .notification(_, _, _, let notification) = message else {
      Issue.record("Expected notification message")
      return
    }
    #expect(notification.agent == "unknown")
  }

  @Test func readPayloadReturnsNilOnReadError() {
    let payload = AgentHookSocketServer.readPayload(from: -1) { _, _ in
      errno = EIO
      return -1
    }

    #expect(payload == nil)
  }
}
