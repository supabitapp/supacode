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

  // MARK: - CLI command message parsing.

  @Test func parsesValidCommandMessage() {
    let json = #"{"deeplink":"supacode://worktree/%2Ftmp%2Frepo/run"}"#
    let message = AgentHookSocketServer.parse(data: Data(json.utf8))

    guard case .command(let url, _) = message else {
      Issue.record("Expected command message, got \(String(describing: message))")
      return
    }
    #expect(url.scheme == "supacode")
    #expect(url.host() == "worktree")
  }

  @Test func rejectsCommandWithInvalidScheme() {
    let json = #"{"deeplink":"https://example.com"}"#
    let message = AgentHookSocketServer.parse(data: Data(json.utf8))
    #expect(message == nil)
  }

  @Test func rejectsCommandWithMalformedJSON() {
    let json = #"{"not_deeplink":"supacode://test"}"#
    let message = AgentHookSocketServer.parse(data: Data(json.utf8))
    #expect(message == nil)
  }

  @Test func commandDoesNotInterfereWithBusyMessages() {
    let tabID = UUID()
    let surfaceID = UUID()
    let raw = "/tmp/repo \(tabID.uuidString) \(surfaceID.uuidString) 1"
    let message = AgentHookSocketServer.parse(data: Data(raw.utf8))

    guard case .busy = message else {
      Issue.record("Expected busy message, got \(String(describing: message))")
      return
    }
  }

  // MARK: - Query message parsing.

  @Test func parsesValidQueryMessage() {
    let json = #"{"query":"repos"}"#
    let message = AgentHookSocketServer.parse(data: Data(json.utf8))

    guard case .query(let resource, let params, _) = message else {
      Issue.record("Expected query message, got \(String(describing: message))")
      return
    }
    #expect(resource == "repos")
    #expect(params.isEmpty)
  }

  @Test func parsesQueryMessageWithParams() {
    let json = #"{"query":"tabs","worktreeID":"/tmp/repo"}"#
    let message = AgentHookSocketServer.parse(data: Data(json.utf8))

    guard case .query(let resource, let params, _) = message else {
      Issue.record("Expected query message, got \(String(describing: message))")
      return
    }
    #expect(resource == "tabs")
    #expect(params["worktreeID"] == "/tmp/repo")
  }

  @Test func queryTakesPrecedenceOverDeeplink() {
    let json = #"{"query":"repos","deeplink":"supacode://worktree/test"}"#
    let message = AgentHookSocketServer.parse(data: Data(json.utf8))

    guard case .query(let resource, _, _) = message else {
      Issue.record("Expected query message, got \(String(describing: message))")
      return
    }
    #expect(resource == "repos")
  }

  @Test func rejectsJSONWithNeitherQueryNorDeeplink() {
    let json = #"{"foo":"bar"}"#
    let message = AgentHookSocketServer.parse(data: Data(json.utf8))
    #expect(message == nil)
  }

  // MARK: - readPayload.

  @Test func readPayloadReturnsNilOnReadError() {
    let payload = AgentHookSocketServer.readPayload(from: -1) { _, _ in
      errno = EIO
      return -1
    }

    #expect(payload == nil)
  }
}
