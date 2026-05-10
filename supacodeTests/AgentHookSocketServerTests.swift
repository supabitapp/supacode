import Darwin
import Foundation
import Testing

@testable import supacode

@MainActor
struct AgentHookSocketServerTests {
  // MARK: - Legacy single-line text payload (no longer parsed).

  @Test func singleLineTextPayloadIsRejected() {
    // The text-protocol busy message (`worktreeID tabID surfaceID 0|1`)
    // was retired in favor of the JSON envelope. Any single-line text
    // header now returns nil — exercises the new guard in `parse`.
    let raw = "wt \(UUID().uuidString) \(UUID().uuidString) 1"
    #expect(AgentHookSocketServer.parse(data: Data(raw.utf8)) == nil)
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

  @Test func parsesNotificationWithAssistantResponseFallback() {
    let tabID = UUID()
    let surfaceID = UUID()
    let payload = #"{"hook_event_name":"stop","assistant_response":"kiro body"}"#
    let raw = "wt \(tabID.uuidString) \(surfaceID.uuidString) kiro\n\(payload)"
    let message = AgentHookSocketServer.parse(data: Data(raw.utf8))

    guard case .notification(_, _, _, let notification) = message else {
      Issue.record("Expected notification message")
      return
    }
    #expect(notification.agent == "kiro")
    #expect(notification.body == "kiro body")
  }

  @Test func lastAssistantMessageTakesPrecedenceOverAssistantResponse() {
    let tabID = UUID()
    let surfaceID = UUID()
    let payload = """
      {"hook_event_name":"Stop","last_assistant_message":"codex body","assistant_response":"kiro body"}
      """
    let raw = "wt \(tabID.uuidString) \(surfaceID.uuidString) codex\n\(payload)"
    let message = AgentHookSocketServer.parse(data: Data(raw.utf8))

    guard case .notification(_, _, _, let notification) = message else {
      Issue.record("Expected notification message")
      return
    }
    #expect(notification.body == "codex body")
  }

  @Test func messageFieldTakesPrecedenceOverAllFallbacks() {
    let tabID = UUID()
    let surfaceID = UUID()
    let payload =
      #"{"hook_event_name":"Stop","message":"primary","#
      + #""last_assistant_message":"secondary","assistant_response":"tertiary"}"#
    let raw = "wt \(tabID.uuidString) \(surfaceID.uuidString) claude\n\(payload)"
    let message = AgentHookSocketServer.parse(data: Data(raw.utf8))

    guard case .notification(_, _, _, let notification) = message else {
      Issue.record("Expected notification message")
      return
    }
    #expect(notification.body == "primary")
  }

  @Test func nullMessageFieldFallsThroughToLastAssistantMessage() {
    let tabID = UUID()
    let surfaceID = UUID()
    let payload = #"{"hook_event_name":"Stop","message":null,"last_assistant_message":"fallback"}"#
    let raw = "wt \(tabID.uuidString) \(surfaceID.uuidString) codex\n\(payload)"
    let message = AgentHookSocketServer.parse(data: Data(raw.utf8))

    guard case .notification(_, _, _, let notification) = message else {
      Issue.record("Expected notification message")
      return
    }
    #expect(notification.body == "fallback")
  }

  @Test func emptyStringMessageFieldFallsThroughToFallback() {
    let tabID = UUID()
    let surfaceID = UUID()
    let payload =
      #"{"hook_event_name":"Stop","message":"","last_assistant_message":"real body"}"#
    let raw = "wt \(tabID.uuidString) \(surfaceID.uuidString) codex\n\(payload)"
    let message = AgentHookSocketServer.parse(data: Data(raw.utf8))

    guard case .notification(_, _, _, let notification) = message else {
      Issue.record("Expected notification message")
      return
    }
    #expect(notification.body == "real body")
  }

  @Test func typeMismatchOnMessageFieldFallsThroughToFallback() {
    let tabID = UUID()
    let surfaceID = UUID()
    // Claude-shape with an unexpectedly numeric message: decoder must
    // tolerate the mismatch and fall through to assistant_response.
    let payload =
      #"{"hook_event_name":"stop","message":42,"assistant_response":"kiro body"}"#
    let raw = "wt \(tabID.uuidString) \(surfaceID.uuidString) kiro\n\(payload)"
    let message = AgentHookSocketServer.parse(data: Data(raw.utf8))

    guard case .notification(_, _, _, let notification) = message else {
      Issue.record("Expected notification message")
      return
    }
    #expect(notification.body == "kiro body")
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
    let raw = "wt not-a-uuid \(surfaceID.uuidString) claude\n{\"hook_event_name\":\"Stop\"}"
    let message = AgentHookSocketServer.parse(data: Data(raw.utf8))
    #expect(message == nil)
  }

  @Test func invalidSurfaceIDReturnsNil() {
    let tabID = UUID()
    let raw = "wt \(tabID.uuidString) not-a-uuid claude\n{\"hook_event_name\":\"Stop\"}"
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

  // MARK: - Hook event JSON envelope.

  @Test func parsesValidHookEventWithRequiredFieldsOnly() {
    let surfaceID = UUID()
    let json = """
      {
        "event": "session_start",
        "v": 1,
        "agent": "claude",
        "surface_id": "\(surfaceID.uuidString)"
      }
      """
    let message = AgentHookSocketServer.parse(data: Data(json.utf8))

    guard case .event(let event) = message else {
      Issue.record("Expected event message, got \(String(describing: message))")
      return
    }
    #expect(event.event == "session_start")
    #expect(event.eventName == .sessionStart)
    #expect(event.agent == "claude")
    #expect(event.surfaceID == surfaceID)
    #expect(event.pid == nil)
    #expect(event.data == nil)
  }

  @Test func parsesHookEventWithPidTimestampAndOpaqueData() {
    let surfaceID = UUID()
    let json = """
      {
        "event": "notification",
        "v": 1,
        "agent": "claude",
        "surface_id": "\(surfaceID.uuidString)",
        "pid": 12345,
        "ts": "2026-05-10T12:00:00Z",
        "data": {"title": "Done", "message": "All good"}
      }
      """
    let message = AgentHookSocketServer.parse(data: Data(json.utf8))

    guard case .event(let event) = message else {
      Issue.record("Expected event message")
      return
    }
    #expect(event.pid == 12345)
    #expect(event.timestamp != nil)

    struct NotificationPayload: Decodable, Equatable {
      let title: String
      let message: String
    }
    let decoded = event.decodeData(NotificationPayload.self)
    #expect(decoded == NotificationPayload(title: "Done", message: "All good"))
  }

  @Test func unknownEventNameKeepsRawStringButHasNilEventName() {
    let surfaceID = UUID()
    let json = """
      {
        "event": "future_event_we_dont_know_yet",
        "v": 1,
        "agent": "claude",
        "surface_id": "\(surfaceID.uuidString)"
      }
      """
    let message = AgentHookSocketServer.parse(data: Data(json.utf8))

    guard case .event(let event) = message else {
      Issue.record("Expected event message")
      return
    }
    #expect(event.event == "future_event_we_dont_know_yet")
    #expect(event.eventName == nil)
  }

  @Test func hookEventMissingSurfaceIDReturnsNil() {
    let json = """
      {
        "event": "session_start",
        "agent": "claude"
      }
      """
    #expect(AgentHookSocketServer.parse(data: Data(json.utf8)) == nil)
  }

  @Test func hookEventWithMalformedSurfaceUUIDReturnsNil() {
    let json = """
      {
        "event": "session_start",
        "agent": "claude",
        "surface_id": "not-a-uuid"
      }
      """
    #expect(AgentHookSocketServer.parse(data: Data(json.utf8)) == nil)
  }

  @Test func eventDiscriminatorTakesPrecedenceOverDeeplinkInSamePayload() {
    let surfaceID = UUID()
    let json = """
      {
        "event": "session_start",
        "agent": "claude",
        "surface_id": "\(surfaceID.uuidString)",
        "deeplink": "supacode://worktree/test"
      }
      """
    let message = AgentHookSocketServer.parse(data: Data(json.utf8))

    guard case .event = message else {
      Issue.record("Expected event message, got \(String(describing: message))")
      return
    }
  }

  @Test func hookEventRejectsNonPositivePid() {
    // `kill(0, 0)` succeeds for the caller's process group and `kill(-N, 0)`
    // for group N, so a pid <= 0 in a session_start would pin a permanent
    // badge in the liveness sweep. Decoder rejects them outright.
    for badPid in ["0", "-1", "-12345"] {
      let json = """
        {
          "event": "session_start",
          "agent": "claude",
          "surface_id": "\(UUID().uuidString)",
          "pid": \(badPid)
        }
        """
      #expect(
        AgentHookSocketServer.parse(data: Data(json.utf8)) == nil,
        "Expected nil for pid=\(badPid)"
      )
    }
  }
}
